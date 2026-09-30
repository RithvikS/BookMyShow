-- =============================================================================
--  BookMyShow-style Ticketing Backend  |  P1 - Schema (DDL)
--  Target  : MySQL 8.0+ (InnoDB, utf8mb4)
--  Run     : mysql -u root -p < sql/01_schema.sql
--
--  Design goals
--    * 1NF / 2NF / 3NF / BCNF: every non-key attribute depends on the key, the
--      whole key and nothing but the key; every determinant is a candidate key.
--    * No double booking: exactly ONE row per (show, seat) in show_seat. The
--      PRIMARY KEY makes a second owner physically impossible, and every write
--      to that row happens under an InnoDB row lock (see 02_procedures.sql).
--    * No lost holds: a hold's expiry lives in the booking row, so it can never
--      be forgotten; expired holds are free for others instantly (lazy expiry)
--      even if the clean-up job is down.
--  All DATETIME values are stored in IST (Asia/Kolkata), the theatre's local time.
-- =============================================================================

DROP DATABASE IF EXISTS bookmyshow;
CREATE DATABASE bookmyshow CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE bookmyshow;

-- -----------------------------------------------------------------------------
-- 1. Location & venue
-- -----------------------------------------------------------------------------
CREATE TABLE city (
    city_id     SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(80)       NOT NULL,
    state       VARCHAR(80)       NOT NULL,
    PRIMARY KEY (city_id),
    UNIQUE KEY uq_city_name_state (name, state)
) ENGINE = InnoDB;

CREATE TABLE theatre (
    theatre_id   INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    city_id      SMALLINT UNSIGNED NOT NULL,
    name         VARCHAR(120)      NOT NULL,
    address_line VARCHAR(255)      NOT NULL,
    created_at   DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (theatre_id),
    UNIQUE KEY uq_theatre_city_name (city_id, name),
    CONSTRAINT fk_theatre_city FOREIGN KEY (city_id) REFERENCES city (city_id)
) ENGINE = InnoDB;

-- Theatre facilities shown on the listing page (M-Ticket, Food & Beverage ...).
-- A separate table instead of a comma-separated column keeps 1NF.
CREATE TABLE amenity (
    amenity_id  SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(60)       NOT NULL,
    PRIMARY KEY (amenity_id),
    UNIQUE KEY uq_amenity_name (name)
) ENGINE = InnoDB;

CREATE TABLE theatre_amenity (
    theatre_id  INT UNSIGNED      NOT NULL,
    amenity_id  SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (theatre_id, amenity_id),
    KEY idx_theatre_amenity_amenity (amenity_id),
    CONSTRAINT fk_ta_theatre FOREIGN KEY (theatre_id) REFERENCES theatre (theatre_id),
    CONSTRAINT fk_ta_amenity FOREIGN KEY (amenity_id) REFERENCES amenity (amenity_id)
) ENGINE = InnoDB;

CREATE TABLE screen (
    screen_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
    theatre_id  INT UNSIGNED NOT NULL,
    name        VARCHAR(40)  NOT NULL,              -- 'Audi 1', 'IMAX'
    PRIMARY KEY (screen_id),
    UNIQUE KEY uq_screen_theatre_name (theatre_id, name),  -- also serves "screens of a theatre"
    CONSTRAINT fk_screen_theatre FOREIGN KEY (theatre_id) REFERENCES theatre (theatre_id)
) ENGINE = InnoDB;

CREATE TABLE seat_type (
    seat_type_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name         VARCHAR(30)      NOT NULL,         -- CLASSIC, PRIME, RECLINER
    PRIMARY KEY (seat_type_id),
    UNIQUE KEY uq_seat_type_name (name)
) ENGINE = InnoDB;

-- The physical seat. Capacity of a screen is COUNT(seat); it is not stored
-- (a stored copy would be a derived, update-anomaly-prone value).
CREATE TABLE seat (
    seat_id      BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    screen_id    INT UNSIGNED      NOT NULL,
    row_label    VARCHAR(2)        NOT NULL,        -- 'A' .. 'H'
    seat_number  TINYINT UNSIGNED  NOT NULL,        -- 1 .. n
    seat_type_id TINYINT UNSIGNED  NOT NULL,
    PRIMARY KEY (seat_id),
    UNIQUE KEY uq_seat_position (screen_id, row_label, seat_number),
    KEY idx_seat_type (seat_type_id),
    CONSTRAINT fk_seat_screen FOREIGN KEY (screen_id)    REFERENCES screen (screen_id),
    CONSTRAINT fk_seat_type   FOREIGN KEY (seat_type_id) REFERENCES seat_type (seat_type_id)
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- 2. Catalogue
-- -----------------------------------------------------------------------------
CREATE TABLE movie (
    movie_id     INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    title        VARCHAR(150)      NOT NULL,
    duration_min SMALLINT UNSIGNED NOT NULL,
    certificate  ENUM ('U', 'UA', 'A', 'S') NOT NULL,
    release_date DATE              NOT NULL,
    PRIMARY KEY (movie_id),
    UNIQUE KEY uq_movie_title_release (title, release_date),
    CONSTRAINT chk_movie_duration CHECK (duration_min BETWEEN 1 AND 600)
) ENGINE = InnoDB;

CREATE TABLE genre (
    genre_id  TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name      VARCHAR(40)      NOT NULL,
    PRIMARY KEY (genre_id),
    UNIQUE KEY uq_genre_name (name)
) ENGINE = InnoDB;

CREATE TABLE movie_genre (           -- many-to-many; keeps genres atomic (1NF)
    movie_id  INT UNSIGNED     NOT NULL,
    genre_id  TINYINT UNSIGNED NOT NULL,
    PRIMARY KEY (movie_id, genre_id),
    KEY idx_movie_genre_genre (genre_id),
    CONSTRAINT fk_mg_movie FOREIGN KEY (movie_id) REFERENCES movie (movie_id),
    CONSTRAINT fk_mg_genre FOREIGN KEY (genre_id) REFERENCES genre (genre_id)
) ENGINE = InnoDB;

CREATE TABLE language (
    language_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(40)      NOT NULL,
    PRIMARY KEY (language_id),
    UNIQUE KEY uq_language_name (name)
) ENGINE = InnoDB;

CREATE TABLE show_format (
    format_id  TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name       VARCHAR(30)      NOT NULL,           -- 2D, 3D, IMAX 2D, 4DX
    PRIMARY KEY (format_id),
    UNIQUE KEY uq_show_format_name (name)
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- 3. Shows (one screening of a movie on a screen at a time)
--    theatre_id is NOT stored here: it is determined by screen_id
--    (screen_id -> theatre_id), so storing it would be a transitive
--    dependency (3NF violation). P2 reaches the theatre through screen.
--    End time is derived (start_time + movie.duration_min), so not stored.
-- -----------------------------------------------------------------------------
CREATE TABLE shows (
    show_id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    movie_id             INT UNSIGNED     NOT NULL,
    screen_id            INT UNSIGNED     NOT NULL,
    language_id          TINYINT UNSIGNED NOT NULL,
    format_id            TINYINT UNSIGNED NOT NULL,
    start_time           DATETIME         NOT NULL,
    status               ENUM ('SCHEDULED', 'CANCELLED') NOT NULL DEFAULT 'SCHEDULED',
    cancellation_allowed BOOLEAN          NOT NULL DEFAULT TRUE,
    PRIMARY KEY (show_id),
    -- a screen cannot start two shows at the same moment; this index is also
    -- the access path for P2: (screen_id = ? AND start_time in [day, day+1))
    UNIQUE KEY uq_show_screen_start (screen_id, start_time),
    KEY idx_show_movie_start (movie_id, start_time),  -- "where is movie X playing"
    KEY idx_show_language (language_id),
    KEY idx_show_format (format_id),
    CONSTRAINT fk_show_movie    FOREIGN KEY (movie_id)    REFERENCES movie (movie_id),
    CONSTRAINT fk_show_screen   FOREIGN KEY (screen_id)   REFERENCES screen (screen_id),
    CONSTRAINT fk_show_language FOREIGN KEY (language_id) REFERENCES language (language_id),
    CONSTRAINT fk_show_format   FOREIGN KEY (format_id)   REFERENCES show_format (format_id)
) ENGINE = InnoDB;

-- Price depends on (show, seat type) - not on the individual seat - so it gets
-- its own table (putting it on show_seat would be a partial dependency).
CREATE TABLE show_price (
    show_id      BIGINT UNSIGNED  NOT NULL,
    seat_type_id TINYINT UNSIGNED NOT NULL,
    price        DECIMAL(8, 2)    NOT NULL,
    PRIMARY KEY (show_id, seat_type_id),
    KEY idx_show_price_type (seat_type_id),
    CONSTRAINT fk_sp_show FOREIGN KEY (show_id)      REFERENCES shows (show_id),
    CONSTRAINT fk_sp_type FOREIGN KEY (seat_type_id) REFERENCES seat_type (seat_type_id),
    CONSTRAINT chk_show_price CHECK (price > 0)
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- 4. Customers, bookings and the seat inventory
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    user_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    full_name   VARCHAR(120)    NOT NULL,
    email       VARCHAR(190)    NOT NULL,
    phone       VARCHAR(15)     NOT NULL,
    created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_email (email),
    UNIQUE KEY uq_users_phone (phone)
) ENGINE = InnoDB;

-- A booking starts life as a timed HOLD (status PENDING + hold_expires_at) and
-- becomes CONFIRMED when the payment webhook arrives in time.
--   idempotency_key : generated by the client once per "Proceed" click, so a
--                     double-click / network retry can never create two holds.
--   The total amount is NOT stored: it is SUM(booking_seat.price) (derived).
CREATE TABLE booking (
    booking_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id         BIGINT UNSIGNED NOT NULL,
    show_id         BIGINT UNSIGNED NOT NULL,
    status          ENUM ('PENDING', 'CONFIRMED', 'EXPIRED', 'CANCELLED') NOT NULL DEFAULT 'PENDING',
    idempotency_key CHAR(36)        NOT NULL,
    hold_expires_at DATETIME(3)     NOT NULL,
    created_at      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    confirmed_at    DATETIME(3)     NULL,
    PRIMARY KEY (booking_id),
    UNIQUE KEY uq_booking_idempotency (user_id, idempotency_key),
    UNIQUE KEY uq_booking_id_show (booking_id, show_id),     -- target of show_seat's composite FK
    KEY idx_booking_show (show_id),
    KEY idx_booking_status_expiry (status, hold_expires_at),  -- clean-up job
    CONSTRAINT fk_booking_user FOREIGN KEY (user_id) REFERENCES users (user_id),
    CONSTRAINT fk_booking_show FOREIGN KEY (show_id) REFERENCES shows (show_id)
) ENGINE = InnoDB;

-- Which seats a booking asked for, with the price charged at that moment
-- (a historical snapshot - later price changes must not alter old bookings).
-- show_id is deliberately absent: booking_id -> show_id already, so repeating it
-- here would be a partial dependency on part of the key (2NF violation).
CREATE TABLE booking_seat (
    booking_id  BIGINT UNSIGNED NOT NULL,
    seat_id     BIGINT UNSIGNED NOT NULL,
    price       DECIMAL(8, 2)   NOT NULL,
    PRIMARY KEY (booking_id, seat_id),
    KEY idx_booking_seat_seat (seat_id),
    CONSTRAINT fk_bs_booking FOREIGN KEY (booking_id) REFERENCES booking (booking_id),
    CONSTRAINT fk_bs_seat    FOREIGN KEY (seat_id)    REFERENCES seat (seat_id)
) ENGINE = InnoDB;

-- THE CONCURRENCY GUARD. One row per (show, seat), created when the show is
-- scheduled. booking_id = the booking that currently owns the seat (NULL = never
-- taken / released). Because (show_id, seat_id) is the PRIMARY KEY, a seat can
-- have at most one owner at any instant - double booking is structurally
-- impossible. The seat's state is derived, never stored twice:
--   AVAILABLE : booking_id IS NULL, or owner is EXPIRED/CANCELLED,
--               or owner is PENDING with hold_expires_at <= NOW()
--   HELD      : owner is PENDING and hold_expires_at > NOW()
--   BOOKED    : owner is CONFIRMED
-- The composite FK (booking_id, show_id) guarantees the owner booking belongs to
-- the SAME show. version supports optimistic (compare-and-set) updates.
CREATE TABLE show_seat (
    show_id     BIGINT UNSIGNED NOT NULL,
    seat_id     BIGINT UNSIGNED NOT NULL,
    booking_id  BIGINT UNSIGNED NULL,
    version     INT UNSIGNED    NOT NULL DEFAULT 0,
    PRIMARY KEY (show_id, seat_id),
    KEY idx_show_seat_booking (booking_id, show_id),
    KEY idx_show_seat_seat (seat_id),
    CONSTRAINT fk_ss_show    FOREIGN KEY (show_id) REFERENCES shows (show_id),
    CONSTRAINT fk_ss_seat    FOREIGN KEY (seat_id) REFERENCES seat (seat_id),
    CONSTRAINT fk_ss_booking FOREIGN KEY (booking_id, show_id) REFERENCES booking (booking_id, show_id)
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- 5. Payments and idempotent webhooks
-- -----------------------------------------------------------------------------
CREATE TABLE payment (
    payment_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    booking_id         BIGINT UNSIGNED NOT NULL,
    gateway            VARCHAR(20)     NOT NULL,     -- RAZORPAY, PAYTM ...
    gateway_order_id   VARCHAR(64)     NOT NULL,     -- created before redirecting the user
    gateway_payment_id VARCHAR(64)     NULL,         -- known once the gateway reports back
    amount             DECIMAL(10, 2)  NOT NULL,
    currency           CHAR(3)         NOT NULL DEFAULT 'INR',
    status             ENUM ('CREATED', 'CAPTURED', 'FAILED', 'REFUND_PENDING', 'REFUNDED') NOT NULL DEFAULT 'CREATED',
    created_at         DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at         DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (payment_id),
    UNIQUE KEY uq_payment_gateway_order (gateway, gateway_order_id),
    UNIQUE KEY uq_payment_gateway_payment (gateway, gateway_payment_id),
    KEY idx_payment_booking (booking_id),
    CONSTRAINT fk_payment_booking FOREIGN KEY (booking_id) REFERENCES booking (booking_id),
    CONSTRAINT chk_payment_amount CHECK (amount > 0)
) ENGINE = InnoDB;

-- Every webhook delivery is recorded once. Gateways deliver "at least once"
-- (retries, duplicates, out-of-order); the PRIMARY KEY on the gateway's own
-- event id turns a duplicate delivery into a no-op (idempotency).
-- payload is kept verbatim as an audit record; it is never queried into.
CREATE TABLE payment_webhook_event (
    gateway      VARCHAR(20)     NOT NULL,
    event_id     VARCHAR(64)     NOT NULL,
    event_type   VARCHAR(40)     NOT NULL,          -- payment.captured, payment.failed
    payment_id   BIGINT UNSIGNED NULL,              -- resolved while processing
    payload      JSON            NOT NULL,
    outcome      VARCHAR(40)     NULL,              -- BOOKING_CONFIRMED, LATE_PAYMENT_REFUND ...
    received_at  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    processed_at DATETIME(3)     NULL,
    PRIMARY KEY (gateway, event_id),
    KEY idx_webhook_payment (payment_id),
    CONSTRAINT fk_webhook_payment FOREIGN KEY (payment_id) REFERENCES payment (payment_id)
) ENGINE = InnoDB;
