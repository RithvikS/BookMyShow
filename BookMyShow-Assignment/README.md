# BookMyShow-Scale Ticketing Backend — P1 & P2

A normalised (BCNF) MySQL schema for a movie-ticketing platform where thousands of users
compete for the same seats. It includes seat-level locking, timed holds that release
automatically, idempotent payment-webhook handling, and a load test that proves it all.

**Main deliverable:** [`docs/BookMyShow_Ticketing_Backend_Design.pdf`](docs/BookMyShow_Ticketing_Backend_Design.pdf)
lists every table and its attributes, gives example rows, and contains the SQL for P1 and P2.
It also explains the normalisation, the locking strategy and the load-test results.

## Folder structure

```
BookMyShow-Assignment/
├── README.md
├── docs/
│   └── BookMyShow_Ticketing_Backend_Design.pdf   <- the submission document
├── sql/
│   ├── 01_schema.sql                     P1  CREATE DATABASE + 20 tables (DDL)
│   ├── 02_procedures.sql                 P1  locking strategy: hold, payment, webhook, expiry
│   ├── 03_sample_data.sql                P1  sample rows (show dates relative to today)
│   ├── 04_p2_shows_by_theatre_and_date.sql  P2  shows at a theatre on a date (+ EXPLAIN)
│   ├── 05_demo_and_checks.sql            walk-through of every guarantee + integrity checks
│   └── bookmyshow_complete.sql           01 + 02 + 03 + 04 in one file (for MySQL Workbench)
└── load_test/
    ├── load_test.py                      concurrency / load test (5 scenarios)
    ├── requirements.txt
    ├── results.json                      results of the run shown in the PDF
    └── results.txt
```

## How to run (MySQL 8.0.4 or newer)

```bash
mysql -u root -p < sql/01_schema.sql
mysql -u root -p bookmyshow < sql/02_procedures.sql
mysql -u root -p bookmyshow < sql/03_sample_data.sql
mysql -u root -p bookmyshow < sql/04_p2_shows_by_theatre_and_date.sql     # P2
mysql -u root -p bookmyshow < sql/05_demo_and_checks.sql                  # optional demo
```

MySQL Workbench: open `sql/bookmyshow_complete.sql` and click **Execute** (⚡).

P2 takes two inputs at the top of `04_p2_shows_by_theatre_and_date.sql`:

```sql
SET @theatre_id = 1;
SET @show_date  = CURDATE() + INTERVAL 1 DAY;   -- or DATE('2026-09-29')
```

Load test (run it on a test database only, because it clears bookings on the shows it uses):

```bash
pip install -r load_test/requirements.txt
python load_test/load_test.py --user root --password <pwd> --users 500 --workers 100
```

## Key design decisions

| Concern | Decision |
|---|---|
| No double booking | `show_seat` has one row per (show, seat), with PRIMARY KEY `(show_id, seat_id)` and `booking_id` = current owner. A seat physically cannot have two owners. |
| Locking | Pessimistic `SELECT … FOR UPDATE` on primary keys, taken in ascending seat order (no deadlocks). Each transaction lasts only milliseconds and runs at READ COMMITTED (no gap locks). |
| Timed holds | The hold is data (`booking.hold_expires_at`), not a lock. **Lazy expiry**: a lapsed hold is bookable the moment it expires. A 30-second clean-up event only tidies up afterwards. |
| Idempotent webhooks | `payment_webhook_event` has PRIMARY KEY `(gateway, event_id)`, and the payment state machine only allows CREATED/FAILED → CAPTURED. A late payment for seats that were resold is refunded. |
| Double-click / retry | `UNIQUE (user_id, idempotency_key)` on `booking`. |
| P2 performance | A SARGable date range on `uq_show_screen_start (screen_id, start_time)`. EXPLAIN shows no table scans. |

## Load-test results (500 users, 100 concurrent connections, MySQL 8.0.46)

| Scenario | Result |
|---|---|
| S1: 500 users click the same 2 seats at once | 1 hold, 499 clean rejections, 0 double bookings |
| S2: 500 users, random 1–4 seat blocks, 80-seat show | seats sold = seats owned ≤ capacity, 0 double bookings, 0 deadlocks |
| S3: 50 webhooks each delivered 5× concurrently | 50 confirmations, 200 duplicates ignored |
| S4: lapsed holds vs new buyers vs late payments | every seat ends with exactly one owner; losers refunded |
| S5: S1 again with optimistic locking | also correct, but 499 wasted transactions and higher latency |

The exact numbers are in the PDF (section 9) and in `load_test/results.json`.
