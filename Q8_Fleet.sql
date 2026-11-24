/* =====================================================================
   ICT371  QUESTION 8 - Transport Fleet Maintenance               [50]
   Service due when current_odometer - last_service_odometer >= 5000 km.
   A new trip must start at the vehicle's current odometer.
   ===================================================================== */
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8, public;

-- Test helper (not part of the marked answer)
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;


/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - Odometers are whole kilometres (INTEGER) and non-negative.
   - CHECK (last_service_odometer <= current_odometer).
   - trips: CHECK (end_odometer > start_odometer) as a table-level backstop.
   - service_alerts: vehicle_id is both PK and FK -> at most ONE alert
     per vehicle.
   - Trips are added through the procedure AFTER the trigger exists
     (as the brief says), so every trip moves the odometer correctly.
   --------------------------------------------------------------------- */
CREATE TABLE vehicles (
    vehicle_id             INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles (vehicle_id),
    trip_on         DATE    NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL,
    CONSTRAINT chk_trip_distance CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles (vehicle_id),
    km_since_service  INTEGER NOT NULL CHECK (km_since_service >= 0),
    flagged_on        DATE    NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles at different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABZ 1234', 120000, 116500),   -- 3 500 km since service: will cross 5 000
    ('BAF 5678',  45200,  45000),   --   200 km: recently serviced
    ('ALT 9012',  80300,  74000);   -- 6 300 km: already overdue


/* ---------------------------------------------------------------------
   (b) FUNCTION fn_service_due                                      [6]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer
    INTO   v_km
    FROM   vehicles
    WHERE  vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle id %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;
END;
$$;


/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_record_trip                                     [8]
   - Validates the vehicle, NULLs and end > start, then INSERTs.
   - It does NOT touch vehicles.current_odometer: the trigger in (d) does
     that. If both did it, the odometer would move twice.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle id %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer values are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer % must be greater than start odometer %', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;


/* ---------------------------------------------------------------------
   (d) TRIGGER: BEFORE INSERT, FOR EACH ROW, on trips                [8]
   1. Read and LOCK the vehicle row (FOR UPDATE): two trips for the same
      vehicle cannot both start at the same odometer value.
   2. Reject invalid mileage (end must be greater than start).
   3. Reject a start that does not equal current_odometer.
   4. Move current_odometer to the trip end. This is the ONLY place it
      is updated, and a row trigger fires once per inserted row, so it is
      updated exactly once per trip.
   If anything later fails (e.g. a constraint on trips), the whole INSERT
   statement is rolled back, including this vehicle UPDATE.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_trips_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current vehicles.current_odometer%TYPE;
BEGIN
    SELECT current_odometer INTO v_current
    FROM   vehicles
    WHERE  vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle id %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip start % does not match vehicle %''s current odometer %',
                        NEW.start_odometer, NEW.vehicle_id, v_current;
    END IF;

    UPDATE vehicles
    SET    current_odometer = NEW.end_odometer
    WHERE  vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_odometer();


-- (a) continued: six trips through the procedure ----------------------
CALL pr_record_trip(1, CURRENT_DATE - 6, 120000, 120800);
CALL pr_record_trip(1, CURRENT_DATE - 3, 120800, 121700);   -- now 5 200 km since service
CALL pr_record_trip(2, CURRENT_DATE - 5,  45200,  45550);
CALL pr_record_trip(2, CURRENT_DATE - 2,  45550,  45800);   -- 800 km, not due
CALL pr_record_trip(3, CURRENT_DATE - 4,  80300,  80950);
CALL pr_record_trip(3, CURRENT_DATE - 1,  80950,  81400);   -- 7 400 km, due

SELECT * FROM vehicles ORDER BY vehicle_id;    -- odometers moved once per trip
SELECT * FROM trips    ORDER BY trip_id;

-- Tests for (b)
SELECT vehicle_id, registration, fn_service_due(vehicle_id) AS service_due
FROM   vehicles ORDER BY vehicle_id;            -- true, false, true
CALL expect_error('SELECT fn_service_due(99)');

-- Tests for (c)
CALL expect_error('CALL pr_record_trip(99, CURRENT_DATE, 0, 10)');           -- unknown vehicle
CALL expect_error('CALL pr_record_trip(2, CURRENT_DATE, 45800, 45800)');     -- end = start

-- Tests for (d): direct SQL is checked too
CALL expect_error($q$INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
                     VALUES (2, CURRENT_DATE, 45000, 45900)$q$);             -- wrong start
SELECT current_odometer AS still_45800 FROM vehicles WHERE vehicle_id = 2;


/* ---------------------------------------------------------------------
   (e) VIEW v_service_due                                           [5]
   Uses the same function as the job, so the 5 000 km rule lives in one
   place.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM   vehicles
WHERE  fn_service_due(vehicle_id);

SELECT * FROM v_service_due ORDER BY registration;   -- ABZ 1234 (5200), ALT 9012 (7400)


/* ---------------------------------------------------------------------
   (f) INDEX                                                         [5]
   Query: WHERE vehicle_id = ? AND trip_on BETWEEN ? AND ?
   - Composite (vehicle_id, trip_on): equality column first, range column
     second, so one vehicle's trips are stored together in date order and
     the date range is one contiguous index slice.
   - (trip_on, vehicle_id) would read all vehicles' trips in the range.
   - It also indexes the FK column vehicle_id.
   --------------------------------------------------------------------- */
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM   trips
WHERE  vehicle_id = 1
AND    trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

SET enable_seqscan = off;     -- tiny table; show the plan used at real volume
EXPLAIN ANALYZE
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM   trips
WHERE  vehicle_id = 1
AND    trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;


/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   Step 1 - upsert: one alert per due vehicle. A new due vehicle is
            inserted; an existing alert gets its km updated (flagged_on
            keeps the date it was FIRST flagged).
   Step 2 - delete: alerts for vehicles no longer due (serviced) are
            removed.
   '0 6 * * 1' = minute 0, hour 6, any day-of-month, any month,
   day-of-week 1 = Monday.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
SET search_path = q8, public
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM   vehicles
    WHERE  fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
    SET    km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    WHERE  NOT fn_service_due(sa.vehicle_id);
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;    -- vehicles 1 and 3

-- Vehicle 3 is serviced -> its alert disappears on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 3;
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();                    -- rerun: no duplicates
SELECT * FROM service_alerts ORDER BY vehicle_id;    -- only vehicle 1

SELECT cron.schedule(
    'q8_refresh_service_alerts',
    '0 6 * * 1',
    $$CALL q8.pr_refresh_service_alerts()$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q8_refresh_service_alerts';
