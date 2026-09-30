-- =============================================================================
--  BookMyShow-style Ticketing Backend  |  P1 - Locking strategy (stored procedures)
--  Target  : MySQL 8.0.4+ (uses JSON_TABLE). Run AFTER 01_schema.sql:
--            mysql -u root -p bookmyshow < sql/02_procedures.sql
--
--  Strategy: PESSIMISTIC row locks (SELECT ... FOR UPDATE) on show_seat, the
--  one-row-per-(show, seat) table, inside short transactions.
--
--  Deadlock prevention
--    1. Every transaction acquires locks in the same order:
--           show_seat rows (ascending seat_id)  ->  booking row(s)
--       sp_hold_seats, sp_process_payment_webhook and sp_release_expired_holds
--       all follow it, so row locks can never wait on each other in a cycle.
--    2. Each procedure runs its transaction at READ COMMITTED, which disables
--       InnoDB gap locks. Under REPEATABLE READ, a range update on a secondary
--       index (e.g. "release every seat of booking X") also locks the gap to the
--       next index entry and can block an unrelated insert -> deadlock.
--    3. Reads that must NOT lock use plain SELECT ... INTO. Inside a procedure,
--       SET v = (SELECT ...) is a LOCKING read and silently breaks rule 1.
--  Rules 2 and 3 were both found by the load test (error 1213 in the expiry
--  race, diagnosed with SHOW ENGINE INNODB STATUS) and fixed.
--
--  Why pessimistic here (and not optimistic)?  A popular show's front rows are
--  a HOT SPOT: hundreds of users click the same seats in the same second. With
--  optimistic version checks all but one of them do the work, fail at commit
--  and retry - wasted round-trips that grow with contention. A row lock makes
--  losers wait a few milliseconds and then get a clean "unavailable" answer.
--  Locks are held only for the few ms the procedure runs (never while the user
--  is paying) - the long 10-minute "hold" is DATA (hold_expires_at), not a lock.
--  An optimistic variant using show_seat.version is shown in 05_demo_and_checks.sql.
-- =============================================================================

USE bookmyshow;

DROP PROCEDURE IF EXISTS sp_hold_seats;
DROP PROCEDURE IF EXISTS sp_create_payment;
DROP PROCEDURE IF EXISTS sp_process_payment_webhook;
DROP PROCEDURE IF EXISTS sp_release_expired_holds;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- sp_hold_seats: atomically hold 1..10 seats of a show for one user.
--   p_seat_ids        JSON array of seat_id, e.g. '[101,102]'
--   p_idempotency_key client-generated UUID; retrying with the same key returns
--                     the same booking instead of creating a second hold
--   p_hold_seconds    hold duration (600 = 10 minutes in production)
--   o_status          HELD | ALREADY_HELD | SEATS_UNAVAILABLE | INVALID_SEATS |
--                     SHOW_NOT_BOOKABLE | BAD_REQUEST
-- -----------------------------------------------------------------------------
CREATE PROCEDURE sp_hold_seats(
    IN  p_user_id         BIGINT UNSIGNED,
    IN  p_show_id         BIGINT UNSIGNED,
    IN  p_seat_ids        JSON,
    IN  p_idempotency_key CHAR(36),
    IN  p_hold_seconds    INT,
    OUT o_booking_id      BIGINT UNSIGNED,
    OUT o_status          VARCHAR(30))
proc:
BEGIN
    DECLARE v_seat_id      BIGINT UNSIGNED;
    DECLARE v_found        TINYINT;
    DECLARE v_owner        BIGINT UNSIGNED;
    DECLARE v_owner_status VARCHAR(20);
    DECLARE v_owner_exp    DATETIME(3);
    DECLARE v_requested    INT;
    DECLARE v_done         TINYINT DEFAULT 0;

    -- seats in ascending order => global lock order => no deadlocks between holds
    DECLARE seat_cursor CURSOR FOR
        SELECT DISTINCT j.seat_id
        FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id BIGINT UNSIGNED PATH '$')) AS j
        ORDER BY j.seat_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- the same idempotency key raced in by a parallel retry: return that booking
    DECLARE EXIT HANDLER FOR 1062
        BEGIN
            ROLLBACK;
            SET o_booking_id = (SELECT booking_id FROM booking
                                WHERE user_id = p_user_id AND idempotency_key = p_idempotency_key);
            SET o_status = 'ALREADY_HELD';
        END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            RESIGNAL;          -- e.g. lock wait timeout: caller may retry
        END;

    SET o_booking_id = NULL;

    -- 1) Idempotent replay (no transaction needed, the key is unique)
    SET o_booking_id = (SELECT booking_id FROM booking
                        WHERE user_id = p_user_id AND idempotency_key = p_idempotency_key);
    IF o_booking_id IS NOT NULL THEN
        SET o_status = 'ALREADY_HELD';
        LEAVE proc;
    END IF;

    -- 2) Request validation
    SET v_requested = (SELECT COUNT(DISTINCT j.seat_id)
                       FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id BIGINT UNSIGNED PATH '$')) AS j);
    IF v_requested = 0 OR v_requested > 10 OR p_hold_seconds <= 0 THEN
        SET o_status = 'BAD_REQUEST';
        LEAVE proc;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM shows
                   WHERE show_id = p_show_id AND status = 'SCHEDULED' AND start_time > NOW()) THEN
        SET o_status = 'SHOW_NOT_BOOKABLE';
        LEAVE proc;
    END IF;

    -- READ COMMITTED: correctness comes from primary-key row locks and unique
    -- keys, not from gap locks. RC turns gap locking off, which removes the
    -- insert-vs-range-scan deadlocks that REPEATABLE READ produces under load.
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;

    -- 3) Create the hold row first (it is new, so nobody else can be waiting on it).
    --    A parallel retry with the same idempotency key fails here with 1062.
    INSERT INTO booking (user_id, show_id, status, idempotency_key, hold_expires_at)
    VALUES (p_user_id, p_show_id, 'PENDING', p_idempotency_key, NOW(3) + INTERVAL p_hold_seconds SECOND);
    SET o_booking_id = LAST_INSERT_ID();

    -- 4) Lock every requested seat (and its current owner booking) in seat order.
    --    A locking read always sees the latest COMMITTED data, so two users can
    --    never both see the same seat as free. Every statement below touches the
    --    seat by its full primary key, so only the requested rows are locked -
    --    other users keep booking other seats of the same show in parallel.
    OPEN seat_cursor;
    lock_loop:
    LOOP
        FETCH seat_cursor INTO v_seat_id;
        IF v_done = 1 THEN
            LEAVE lock_loop;
        END IF;

        SET v_found = 0;
        SELECT 1, ss.booking_id, b.status, b.hold_expires_at
        INTO v_found, v_owner, v_owner_status, v_owner_exp
        FROM show_seat ss
                 LEFT JOIN booking b ON b.booking_id = ss.booking_id
        WHERE ss.show_id = p_show_id
          AND ss.seat_id = v_seat_id
        FOR UPDATE;

        IF v_found = 0 THEN                   -- seat is not part of this show
            CLOSE seat_cursor;
            ROLLBACK;
            SET o_booking_id = NULL;
            SET o_status = 'INVALID_SEATS';
            LEAVE proc;
        END IF;

        IF NOT (v_owner IS NULL
            OR v_owner_status IN ('EXPIRED', 'CANCELLED')
            OR (v_owner_status = 'PENDING' AND v_owner_exp <= NOW(3))) THEN
            CLOSE seat_cursor;
            ROLLBACK;                         -- undoes the hold row, releases all locks
            SET o_booking_id = NULL;
            SET o_status = 'SEATS_UNAVAILABLE';
            LEAVE proc;
        END IF;

        -- a lapsed hold we are taking over is marked EXPIRED, so a late payment
        -- for it can never confirm (the webhook refunds it instead)
        IF v_owner_status = 'PENDING' THEN
            UPDATE booking SET status = 'EXPIRED'
            WHERE booking_id = v_owner AND status = 'PENDING';
        END IF;

        -- price snapshot for this seat (seat type -> show price)
        INSERT INTO booking_seat (booking_id, seat_id, price)
        SELECT o_booking_id, s.seat_id, sp.price
        FROM seat s
                 JOIN show_price sp ON sp.show_id = p_show_id AND sp.seat_type_id = s.seat_type_id
        WHERE s.seat_id = v_seat_id;

        IF ROW_COUNT() <> 1 THEN               -- no price configured for this seat type
            CLOSE seat_cursor;
            ROLLBACK;
            SET o_booking_id = NULL;
            SET o_status = 'INVALID_SEATS';
            LEAVE proc;
        END IF;

        UPDATE show_seat
        SET booking_id = o_booking_id,
            version    = version + 1
        WHERE show_id = p_show_id
          AND seat_id = v_seat_id;
    END LOOP;
    CLOSE seat_cursor;

    COMMIT;
    SET o_status = 'HELD';
END$$

-- -----------------------------------------------------------------------------
-- sp_create_payment: open a gateway order for a live hold. The amount is
-- computed from booking_seat (never trusted from the client).
-- -----------------------------------------------------------------------------
CREATE PROCEDURE sp_create_payment(
    IN  p_booking_id       BIGINT UNSIGNED,
    IN  p_gateway          VARCHAR(20),
    IN  p_gateway_order_id VARCHAR(64),
    OUT o_payment_id       BIGINT UNSIGNED,
    OUT o_amount           DECIMAL(10, 2))
BEGIN
    SET o_payment_id = NULL;
    SET o_amount = NULL;

    IF EXISTS (SELECT 1 FROM booking
               WHERE booking_id = p_booking_id AND status = 'PENDING' AND hold_expires_at > NOW(3)) THEN
        INSERT INTO payment (booking_id, gateway, gateway_order_id, amount)
        SELECT booking_id, p_gateway, p_gateway_order_id, SUM(price)
        FROM booking_seat
        WHERE booking_id = p_booking_id
        GROUP BY booking_id;
        SET o_payment_id = LAST_INSERT_ID();
        SET o_amount = (SELECT amount FROM payment WHERE payment_id = o_payment_id);
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- sp_process_payment_webhook: idempotent handler for gateway callbacks.
--   * The same event delivered N times (even concurrently) is applied once:
--     the PRIMARY KEY (gateway, event_id) admits one insert; the others hit
--     duplicate-key and return DUPLICATE_EVENT.
--   * A second, different event for an already-captured payment is ignored
--     (state machine: only CREATED/FAILED -> CAPTURED).
--   * A payment that arrives after the hold lapsed confirms ONLY if nobody has
--     taken any of the seats meanwhile; otherwise it is flagged for refund.
--   o_result: BOOKING_CONFIRMED | DUPLICATE_EVENT | ALREADY_APPLIED |
--             LATE_PAYMENT_REFUND | DUPLICATE_PAYMENT_REFUND | AMOUNT_MISMATCH |
--             PAYMENT_FAILED | UNKNOWN_ORDER | IGNORED_EVENT
-- -----------------------------------------------------------------------------
CREATE PROCEDURE sp_process_payment_webhook(
    IN  p_gateway            VARCHAR(20),
    IN  p_event_id           VARCHAR(64),
    IN  p_event_type         VARCHAR(40),
    IN  p_gateway_order_id   VARCHAR(64),
    IN  p_gateway_payment_id VARCHAR(64),
    IN  p_amount             DECIMAL(10, 2),
    IN  p_payload            JSON,
    OUT o_result             VARCHAR(40))
proc:
BEGIN
    DECLARE v_duplicate      TINYINT DEFAULT 0;
    DECLARE v_found          TINYINT DEFAULT 0;
    DECLARE v_payment_id     BIGINT UNSIGNED;
    DECLARE v_booking_id     BIGINT UNSIGNED;
    DECLARE v_show_id        BIGINT UNSIGNED;
    DECLARE v_pay_status     VARCHAR(20);
    DECLARE v_pay_amount     DECIMAL(10, 2);
    DECLARE v_booking_status VARCHAR(20);
    DECLARE v_total          INT;
    DECLARE v_owned          INT;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;          -- event row rolled back too, so a gateway retry is processed cleanly
            RESIGNAL;
        END;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;    -- see sp_hold_seats
    START TRANSACTION;

    -- 1) Dedupe: record the event; a duplicate key means it was already handled
    BEGIN
        DECLARE CONTINUE HANDLER FOR 1062 SET v_duplicate = 1;
        INSERT INTO payment_webhook_event (gateway, event_id, event_type, payload)
        VALUES (p_gateway, p_event_id, p_event_type, p_payload);
    END;
    IF v_duplicate = 1 THEN
        ROLLBACK;
        SET o_result = 'DUPLICATE_EVENT';
        LEAVE proc;
    END IF;

    -- 2) Lock the payment row (serialises different events of the same payment)
    SET v_found = 1;
    SELECT payment_id, booking_id, status, amount
    INTO v_payment_id, v_booking_id, v_pay_status, v_pay_amount
    FROM payment
    WHERE gateway = p_gateway AND gateway_order_id = p_gateway_order_id
    FOR UPDATE;

    IF v_found = 0 THEN
        SET o_result = 'UNKNOWN_ORDER';
    ELSEIF p_event_type = 'payment.failed' THEN
        IF v_pay_status = 'CREATED' THEN
            UPDATE payment SET status = 'FAILED', gateway_payment_id = p_gateway_payment_id
            WHERE payment_id = v_payment_id;
            SET o_result = 'PAYMENT_FAILED';   -- hold stays; user may retry until it expires
        ELSE
            SET o_result = 'ALREADY_APPLIED';
        END IF;
    ELSEIF p_event_type <> 'payment.captured' THEN
        SET o_result = 'IGNORED_EVENT';
    ELSEIF v_pay_status NOT IN ('CREATED', 'FAILED') THEN
        SET o_result = 'ALREADY_APPLIED';
    ELSEIF p_amount <> v_pay_amount THEN
        UPDATE payment SET status = 'REFUND_PENDING', gateway_payment_id = p_gateway_payment_id
        WHERE payment_id = v_payment_id;
        SET o_result = 'AMOUNT_MISMATCH';
    ELSE
        -- 3) Lock the booking's seats FIRST (same order as sp_hold_seats), then the booking
        -- plain SELECT ... INTO = non-locking read. (SET v = (SELECT ...) would take a
        -- shared lock on the booking row BEFORE the seats - breaking the lock order.)
        SELECT show_id INTO v_show_id FROM booking WHERE booking_id = v_booking_id;

        SELECT COUNT(*), COALESCE(SUM(ss.booking_id <=> v_booking_id), 0)
        INTO v_total, v_owned
        FROM booking_seat bs
                 JOIN show_seat ss ON ss.show_id = v_show_id AND ss.seat_id = bs.seat_id
        WHERE bs.booking_id = v_booking_id
        FOR UPDATE OF ss;

        SELECT status INTO v_booking_status
        FROM booking WHERE booking_id = v_booking_id
        FOR UPDATE;

        IF v_booking_status = 'CONFIRMED' THEN
            -- booking already paid through another order: refund this one, keep seats
            UPDATE payment SET status = 'REFUND_PENDING', gateway_payment_id = p_gateway_payment_id
            WHERE payment_id = v_payment_id;
            SET o_result = 'DUPLICATE_PAYMENT_REFUND';
        ELSEIF v_booking_status = 'PENDING' AND v_total > 0 AND v_owned = v_total THEN
            -- still owns every seat (even if the timer just lapsed, nobody took them)
            UPDATE booking SET status = 'CONFIRMED', confirmed_at = NOW(3)
            WHERE booking_id = v_booking_id;
            UPDATE payment SET status = 'CAPTURED', gateway_payment_id = p_gateway_payment_id
            WHERE payment_id = v_payment_id;
            SET o_result = 'BOOKING_CONFIRMED';
        ELSE
            -- hold lost (some seats re-sold): release what is left, refund the money
            UPDATE show_seat SET booking_id = NULL, version = version + 1
            WHERE show_id = v_show_id AND booking_id = v_booking_id;
            UPDATE booking SET status = 'EXPIRED'
            WHERE booking_id = v_booking_id AND status = 'PENDING';
            UPDATE payment SET status = 'REFUND_PENDING', gateway_payment_id = p_gateway_payment_id
            WHERE payment_id = v_payment_id;
            SET o_result = 'LATE_PAYMENT_REFUND';
        END IF;
    END IF;

    UPDATE payment_webhook_event
    SET payment_id = v_payment_id, outcome = o_result, processed_at = NOW(3)
    WHERE gateway = p_gateway AND event_id = p_event_id;

    COMMIT;
END$$

-- -----------------------------------------------------------------------------
-- sp_release_expired_holds: housekeeping job (run every ~30 s by a scheduler or
-- the MySQL EVENT below). Correctness does NOT depend on it - expired holds are
-- already bookable (lazy expiry) - it just returns seats to NULL and marks
-- bookings EXPIRED so dashboards and seat maps stay tidy. One booking per
-- transaction keeps each lock set tiny; lock order is seats -> booking.
-- -----------------------------------------------------------------------------
CREATE PROCEDURE sp_release_expired_holds(IN p_batch_size INT, OUT o_released INT)
BEGIN
    DECLARE v_booking_id BIGINT UNSIGNED;
    DECLARE v_done       TINYINT DEFAULT 0;
    DECLARE v_status     VARCHAR(20);
    DECLARE v_expiry     DATETIME(3);
    DECLARE v_dummy      INT;

    DECLARE expired_cursor CURSOR FOR
        SELECT booking_id FROM booking
        WHERE status = 'PENDING' AND hold_expires_at <= NOW(3)
        ORDER BY hold_expires_at
        LIMIT p_batch_size;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            RESIGNAL;
        END;

    SET o_released = 0;
    OPEN expired_cursor;
    release_loop:
    LOOP
        FETCH expired_cursor INTO v_booking_id;
        IF v_done = 1 THEN
            LEAVE release_loop;
        END IF;

        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;  -- see sp_hold_seats
        START TRANSACTION;
        -- seats first ...
        SELECT COUNT(*) INTO v_dummy
        FROM show_seat
        WHERE booking_id = v_booking_id
        FOR UPDATE;
        -- ... then the booking, re-checked under lock (a webhook may have confirmed it)
        SELECT status, hold_expires_at INTO v_status, v_expiry
        FROM booking WHERE booking_id = v_booking_id
        FOR UPDATE;

        IF v_status = 'PENDING' AND v_expiry <= NOW(3) THEN
            UPDATE show_seat SET booking_id = NULL, version = version + 1
            WHERE booking_id = v_booking_id;
            UPDATE booking SET status = 'EXPIRED' WHERE booking_id = v_booking_id;
            SET o_released = o_released + 1;
        END IF;
        COMMIT;
    END LOOP;
    CLOSE expired_cursor;
END$$

DELIMITER ;

-- Optional: let MySQL run the clean-up itself (requires event_scheduler=ON).
DROP EVENT IF EXISTS ev_release_expired_holds;
CREATE EVENT ev_release_expired_holds
    ON SCHEDULE EVERY 30 SECOND
    DO CALL sp_release_expired_holds(500, @released);
