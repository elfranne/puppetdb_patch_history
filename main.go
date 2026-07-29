// Command puppetdb_patch_history copies package-update events from PuppetDB into
// the patch_history archive database.
//
// PuppetDB expires reports after report-ttl (14 days by default), so this is
// run on a timer to keep a permanent record of what was patched where.
//
// It is safe to run repeatedly and safe to re-run after a crash: the watermark
// is derived from the archive itself, and each Puppet run is inserted in a
// single transaction keyed on the report hash.
//
// It does not create its own tables. The archive schema is applied out of band -
// by the example Puppet profile, or by hand - so this command's database role can
// be append-only and hold no CREATE privilege: it should not be able to drop an
// archive that exists precisely because PuppetDB has already discarded the data.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// schemaName is where the archive lives. It is a constant rather than a flag
// because it is an SQL identifier, not a value: making it configurable would mean
// interpolating it into every query and quoting it correctly to stay safe.
// It must match the schema the Puppet profile creates.
const schemaName = "patch_history"

// undefinedTable is SQLSTATE 42P01, raised when a relation does not exist.
// Spelled out rather than pulling in github.com/jackc/pgerrcode for one constant.
const undefinedTable = "42P01"

type config struct {
	puppetDB   string
	dbURL      string
	pageSize   int
	since      string
	backfill   time.Duration
	grace      time.Duration
	classMatch string
	timeout    time.Duration
	dryRun     bool
	verbose    bool
}

func (c config) validate() error {
	if c.pageSize <= 0 {
		return fmt.Errorf("-page-size must be positive, got %d", c.pageSize)
	}
	if c.timeout <= 0 {
		return fmt.Errorf("-timeout must be positive, got %s", c.timeout)
	}
	if c.backfill < 0 {
		return fmt.Errorf("-backfill cannot be negative, got %s", c.backfill)
	}
	if c.grace < 0 {
		return fmt.Errorf("-grace cannot be negative, got %s", c.grace)
	}
	return nil
}

// event is one resource_event row from PuppetDB.
//
// old_value and new_value are kept raw because package providers are not
// consistent about their shape: usually a version string, sometimes "absent",
// sometimes an array of candidate versions, sometimes null.
type event struct {
	Certname          string          `json:"certname"`
	Report            string          `json:"report"`
	RunStartTime      time.Time       `json:"run_start_time"`
	ReportReceiveTime time.Time       `json:"report_receive_time"`
	Resource          string          `json:"resource_title"`
	OldValue          json.RawMessage `json:"old_value"`
	NewValue          json.RawMessage `json:"new_value"`
	Status            string          `json:"status"`
}

type pkg struct {
	name       string
	oldVersion string
	newVersion string
	status     string
}

// patchRun is one Puppet run's worth of package changes on one node.
//
// runAt is when the run started, which is what reporting cares about. receivedAt
// is when PuppetDB accepted the report, which is what the watermark is built on.
type patchRun struct {
	certname   string
	reportHash string
	runAt      time.Time
	receivedAt time.Time
	packages   []pkg
}

func main() {
	cfg := config{}

	flag.StringVar(&cfg.puppetDB, "puppetdb", envOr("PUPPETDB_URL", "http://localhost:8080"),
		"PuppetDB base URL")
	flag.StringVar(&cfg.dbURL, "db", envOr("DATABASE_URL", "postgres:///patch_history?host=/var/run/postgresql"),
		"PostgreSQL connection string (defaults to the local unix socket)")
	flag.IntVar(&cfg.pageSize, "page-size", 5000, "events fetched per PuppetDB query")
	flag.StringVar(&cfg.since, "since", "",
		"RFC3339 report receive time to import from, overriding the watermark (for backfills)")
	flag.DurationVar(&cfg.backfill, "backfill", 30*24*time.Hour,
		"how far back to look when the archive is empty")
	flag.DurationVar(&cfg.grace, "grace", time.Hour,
		"how far back before the watermark to re-check, for reports that become visible out of order")
	flag.StringVar(&cfg.classMatch, "containing-class", "",
		"regex matched against containing_class, to exclude non-patching package changes")
	flag.DurationVar(&cfg.timeout, "timeout", 10*time.Minute, "overall deadline")
	flag.BoolVar(&cfg.dryRun, "dry-run", false, "fetch and report, but write nothing")
	flag.BoolVar(&cfg.verbose, "verbose", false, "log every PuppetDB page fetch")
	flag.Parse()

	level := slog.LevelInfo
	if cfg.verbose {
		level = slog.LevelDebug
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	if err := run(cfg, logger); err != nil {
		logger.Error("import failed", "err", err)
		os.Exit(1)
	}
}

func run(cfg config, logger *slog.Logger) error {
	if err := cfg.validate(); err != nil {
		return err
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	ctx, cancelTimeout := context.WithTimeout(ctx, cfg.timeout)
	defer cancelTimeout()

	conn, err := pgx.Connect(ctx, cfg.dbURL)
	if err != nil {
		return fmt.Errorf("connect to archive: %w", err)
	}
	defer func() { _ = conn.Close(context.Background()) }()

	since, err := watermark(ctx, conn, cfg)
	if err != nil {
		return fmt.Errorf("determine watermark: %w", err)
	}
	logger.Info("importing", "since", since.Format(time.RFC3339))

	events, err := fetchEvents(ctx, cfg, since, logger)
	if err != nil {
		return fmt.Errorf("fetch events: %w", err)
	}
	if len(events) == 0 {
		logger.Info("nothing to import")
		return nil
	}

	runs := groupByReport(events)
	logger.Info("fetched", "events", len(events), "runs", len(runs))

	if cfg.dryRun {
		for _, r := range runs {
			logger.Info("would import", "certname", r.certname,
				"run_at", r.runAt.Format(time.RFC3339), "packages", len(r.packages))
		}
		return nil
	}

	var imported, skipped int
	for _, r := range runs {
		inserted, err := insertRun(ctx, conn, r)
		if err != nil {
			return fmt.Errorf("insert run %s for %s: %w", r.reportHash, r.certname, err)
		}
		if inserted {
			imported++
		} else {
			skipped++
		}
	}

	logger.Info("done", "runs_imported", imported, "runs_already_present", skipped)
	return nil
}

// watermark returns the report receive time to import from. Deriving it from the
// archive rather than a state file is what makes the job crash-safe: a failed run
// simply re-fetches the same window next time.
//
// It is deliberately built on report_received_at and not run_at. A report only
// becomes queryable once the run finishes, so a run that took twenty minutes lands
// after a two-minute run that started later. Watermarking on the start time would
// leave the long run permanently below the cutoff, and it would be lost for good
// once PuppetDB expired it.
func watermark(ctx context.Context, conn *pgx.Conn, cfg config) (time.Time, error) {
	if cfg.since != "" {
		return time.Parse(time.RFC3339, cfg.since)
	}

	var max *time.Time
	err := conn.QueryRow(ctx,
		`SELECT max(report_received_at) FROM `+schemaName+`.patch_run`).Scan(&max)
	if err != nil {
		// This is the first query the importer runs, so a missing archive surfaces
		// here. The tables are applied out of band now, so this is something the
		// operator has to act on rather than something the next run repairs.
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == undefinedTable {
			return time.Time{}, fmt.Errorf(
				"archive schema is missing: %s.patch_run does not exist. Apply the schema "+
					"first - see example/INSTALL.md: %w", schemaName, err)
		}
		return time.Time{}, err
	}
	if max == nil {
		return time.Now().Add(-cfg.backfill), nil
	}

	// Step back by the grace window. Receive times are assigned when PuppetDB
	// accepts a report, but reports do not become visible in exactly that order, so
	// one received just before the newest we hold can show up after it. Re-reading
	// the window costs nothing: the report_hash conflict makes it a no-op.
	return max.Add(-cfg.grace), nil
}

func buildPQL(cfg config, since time.Time, offset int) string {
	var b strings.Builder

	b.WriteString(`events[certname, report, run_start_time, report_receive_time, resource_title, old_value, new_value, status] { `)
	b.WriteString(`resource_type = "Package" and property = "ensure" `)
	b.WriteString(`and (status = "success" or status = "failure") `)

	// Bounded on receive time rather than start time, for the reason in watermark.
	fmt.Fprintf(&b, `and report_receive_time >= "%s" `, since.UTC().Format(time.RFC3339))

	if cfg.classMatch != "" {
		fmt.Fprintf(&b, `and containing_class ~ %s `, quotePQL(cfg.classMatch))
	}

	// report and resource_title are tiebreakers, and they are not optional: every
	// event in a run carries that run's receive time, so receive time alone is not a
	// total order and rows with equal keys could land in no page at all as the offset
	// walks forward. Ordering by receive time ascending also means reports arriving
	// mid-import only ever append past the last page, instead of shifting rows that
	// earlier pages already stepped over.
	fmt.Fprintf(&b,
		`order by report_receive_time asc, report asc, resource_title asc limit %d offset %d }`,
		cfg.pageSize, offset)
	return b.String()
}

// quotePQL renders s as a PQL string literal. PQL has no bind parameters, so the
// value has to be escaped by hand. Escaping the backslash is what matters most
// here: without it a regex like `\d` reaches PuppetDB as an unknown string
// escape rather than as a regex.
func quotePQL(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}

func fetchEvents(ctx context.Context, cfg config, since time.Time, logger *slog.Logger) ([]event, error) {
	client := &http.Client{}
	endpoint := strings.TrimSuffix(cfg.puppetDB, "/") + "/pdb/query/v4"

	var all []event
	for offset := 0; ; offset += cfg.pageSize {
		body, err := json.Marshal(map[string]string{"query": buildPQL(cfg, since, offset)})
		if err != nil {
			return nil, err
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}

		payload, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			return nil, err
		}
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("puppetdb returned %s: %s", resp.Status, strings.TrimSpace(string(payload)))
		}

		var page []event
		if err := json.Unmarshal(payload, &page); err != nil {
			return nil, fmt.Errorf("decode puppetdb response: %w", err)
		}

		all = append(all, page...)
		logger.Debug("fetched page", "offset", offset, "events", len(page))

		if len(page) < cfg.pageSize {
			return all, nil
		}
	}
}

// groupByReport collects events into Puppet runs.
//
// Grouping on the report hash matters: the per-event `timestamp` field is when
// that individual resource was evaluated, so it differs between packages in the
// same run. The report hash is the only field that identifies a single run.
func groupByReport(events []event) []*patchRun {
	byReport := make(map[string]*patchRun)
	var order []*patchRun

	for _, e := range events {
		if e.Report == "" {
			continue
		}

		r, ok := byReport[e.Report]
		if !ok {
			r = &patchRun{
				certname:   e.Certname,
				reportHash: e.Report,
				runAt:      e.RunStartTime,
				receivedAt: e.ReportReceiveTime,
			}
			byReport[e.Report] = r
			order = append(order, r)
		}

		r.packages = append(r.packages, pkg{
			name:       e.Resource,
			oldVersion: normalizeValue(e.OldValue),
			newVersion: normalizeValue(e.NewValue),
			status:     e.Status,
		})
	}

	return order
}

// normalizeValue flattens a PuppetDB event value into a string. Package
// providers return a bare version string most of the time, "absent" for a
// package that was not previously installed, and occasionally an array.
func normalizeValue(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}

	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}

	var list []string
	if err := json.Unmarshal(raw, &list); err == nil {
		return strings.Join(list, ",")
	}

	return strings.Trim(string(raw), `"`)
}

// insertRun writes one Puppet run and its packages atomically. It reports
// whether the run was new; an existing report_hash means we have it already.
func insertRun(ctx context.Context, conn *pgx.Conn, r *patchRun) (bool, error) {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback(context.Background()) }()

	var runID int64
	err = tx.QueryRow(ctx,
		`INSERT INTO `+schemaName+`.patch_run (certname, report_hash, run_at, report_received_at)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (report_hash) DO NOTHING
		 RETURNING id`,
		r.certname, r.reportHash, r.runAt, r.receivedAt,
	).Scan(&runID)

	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}

	// pgx.Identifier is a slice of name parts and quotes each, so this becomes
	// "patch_history"."patch_package".
	_, err = tx.CopyFrom(ctx,
		pgx.Identifier{schemaName, "patch_package"},
		[]string{"run_id", "package", "old_version", "new_version", "status"},
		pgx.CopyFromSlice(len(r.packages), func(i int) ([]any, error) {
			p := r.packages[i]
			return []any{runID, p.name, nullable(p.oldVersion), nullable(p.newVersion), p.status}, nil
		}),
	)
	if err != nil {
		return false, err
	}

	return true, tx.Commit(ctx)
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}