-- Synthetic integration data only. Run once as a local PostgreSQL administrator
-- in a NEW disposable database named pulse_test_*. This never creates or replaces
-- a database, drops existing objects, or changes an existing role.
-- The new pulse_reader LOGIN has no password until you set one with \password.

BEGIN;

DO $$
BEGIN
    IF strpos(current_database(), 'pulse_test_') <> 1 THEN
        RAISE EXCEPTION 'This fixture requires a disposable database named pulse_test_*';
    END IF;
END
$$;

CREATE ROLE pulse_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE pulse_reader SET default_transaction_read_only = on;

CREATE TABLE public.users (
    id text PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE public.bookings (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id text REFERENCES public.users(id),
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.users (id, name)
SELECT 'u' || lpad(i::text, 2, '0'),
       CASE WHEN i <= 2 THEN 'Shared name' ELSE 'User ' || lpad(i::text, 2, '0') END
FROM generate_series(1, 14) AS i;

INSERT INTO public.bookings (user_id)
SELECT 'u' || lpad(i::text, 2, '0')
FROM (VALUES (1, 12), (2, 8), (3, 5), (4, 4), (5, 3),
             (6, 2), (7, 1), (8, 1), (9, 1)) AS counts(i, total)
CROSS JOIN LATERAL generate_series(1, total);
INSERT INTO public.bookings (user_id) VALUES (NULL);

CREATE SCHEMA empty_data;
CREATE TABLE empty_data.users (id text PRIMARY KEY, name text);
CREATE TABLE empty_data.bookings (
    id bigint PRIMARY KEY,
    user_id text REFERENCES empty_data.users(id)
);
CREATE SCHEMA hidden;
CREATE TABLE hidden.private_records (id bigint PRIMARY KEY);

REVOKE ALL ON SCHEMA public, empty_data, hidden FROM PUBLIC;
GRANT USAGE ON SCHEMA public, empty_data TO pulse_reader;
GRANT SELECT ON public.users, public.bookings,
                empty_data.users, empty_data.bookings TO pulse_reader;

DO $$
BEGIN
    EXECUTE format('REVOKE CREATE, TEMPORARY ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO pulse_reader', current_database());
    IF (SELECT count(*) FROM public.users) <> 14
       OR (SELECT count(*) FROM public.bookings) <> 38
       OR (SELECT count(*) FROM public.bookings WHERE user_id IS NOT NULL) <> 37
       OR (SELECT count(DISTINCT user_id) FROM public.bookings) <> 9
       OR (SELECT count(*) FROM public.users u WHERE NOT EXISTS
           (SELECT 1 FROM public.bookings b WHERE b.user_id = u.id)) <> 5 THEN
        RAISE EXCEPTION 'Unexpected synthetic analytics fixture totals';
    END IF;
END
$$;

COMMIT;
