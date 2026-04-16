# portal-schema

SQL migration files for the PostgreSQL database backing a Rust customer portal for managing network infrastructure deployed at multi-family residential properties (apartment complexes, student housing, mixed-use buildings, etc.). The platform serves three user classes:

- **Residents** — self-service portal: manage devices, view usage, upgrade service plans, pay bills, submit support tickets
- **Property managers** — operational dashboard: monitor network health per property/unit, manage resident accounts and credentials, view analytics and reports
- **Service provider staff / NOC** — full platform visibility: portfolio-wide oversight, device auto-configuration, support ticket management, KPI monitoring, 24/7 network monitoring

## Stack

- **Database**: PostgreSQL 18+
- **Migration tool**: [Refinery](https://github.com/rust-db/refinery) v0.9
- **Rust DB client**: [tokio-postgres](https://crates.io/crates/tokio-postgres)

## Repository Layout

```
migrations/
  V1__initial_schema.sql
  V2__add_sessions.sql
  ...
```

All migration files live in `migrations/`. No other directories are needed.

## Migration File Conventions

Refinery file naming format: `[V|U]{version}__{description}.sql`

- **`V` (versioned/contiguous)** — use for this project. Migrations must be applied in strict sequential order. Each new file gets the next integer version.
- **`U` (unversioned/non-contiguous)** — allows gaps in version numbers; useful when multiple developers may merge migrations out of order. Prefer `V` unless parallel development requires `U`.

Rules:
- Double underscore `__` separates the version from the description.
- Description uses `snake_case`.
- Versions are `i32` by default (enable `int8-versions` feature to use `i64`).
- Never edit or delete an applied migration. To undo a change, add a new migration.
- Each migration runs in its own transaction by default.

Examples:
```
V1__create_organizations.sql
V2__create_users.sql
V3__create_sessions.sql
V4__add_user_role_column.sql
```

## PostgreSQL Type Guidelines

Choose the most semantically appropriate PostgreSQL type. The table below shows the canonical Rust mapping used by tokio-postgres (with common feature flags noted).

| Use case | PostgreSQL type | Rust type | Feature flag |
|---|---|---|---|
| Boolean flag | `BOOLEAN` | `bool` | — |
| Small integer / enum code | `SMALLINT` | `i16` | — |
| Standard integer / counts | `INTEGER` | `i32` | — |
| Large integer / snowflake IDs | `BIGINT` | `i64` | — |
| Internal surrogate PK | `BIGSERIAL` | `i64` | — |
| Public API identifier | `UUID` | `uuid::Uuid` | `with-uuid-1` |
| Floating point (low precision) | `REAL` | `f32` | — |
| Floating point (high precision) | `DOUBLE PRECISION` | `f64` | — |
| Money / exact decimal | `NUMERIC(p, s)` | `rust_decimal::Decimal` | `with-rust_decimal` |
| Short text / identifiers | `TEXT` | `String` | — |
| Binary data | `BYTEA` | `Vec<u8>` | — |
| Foreign keys (internal joins) | `BIGINT` | `i64` | — |
| Absolute timestamp | `TIMESTAMPTZ` | `chrono::DateTime<Utc>` | `with-chrono-0_4` |
| Local/naive timestamp | `TIMESTAMP` | `chrono::NaiveDateTime` | `with-chrono-0_4` |
| Date only | `DATE` | `chrono::NaiveDate` | `with-chrono-0_4` |
| Structured / semi-structured data | `JSONB` | `serde_json::Value` | `with-serde_json-1` |
| IP address | `INET` | `std::net::IpAddr` | — |
| MAC address | `MACADDR` | `eui48::MacAddress` | `with-eui48-1` |
| Text search | `TSVECTOR` | — | use `to_tsvector()` |
| Enumerated set | custom `ENUM` | custom type impl `ToSql`+`FromSql` | — |
| Arrays | `TEXT[]`, `INTEGER[]`, etc. | `Vec<T>` | — |

**Avoid** `SERIAL`/`SMALLSERIAL` (prefer `GENERATED ALWAYS AS IDENTITY` or explicit `BIGSERIAL`).  
**Avoid** `CHAR(n)` — use `TEXT` with a `CHECK` constraint when length matters.  
**Avoid** `TIMESTAMP WITHOUT TIME ZONE` for user-facing data — always use `TIMESTAMPTZ`.  
**Avoid** exposing `BIGSERIAL` / integer PKs in public APIs — use the `uuid` column instead to prevent enumeration attacks.

## Schema Conventions

- Every table has a `BIGSERIAL` primary key named `id` used exclusively for internal joins and foreign key references.
- Every table also has a `UUID` column named `uuid` with default `uuidv7()` and a `UNIQUE` constraint, used as the stable public identifier exposed in APIs. UUIDv7 is time-ordered, making it index-friendly and sortable by creation time unlike v4. `uuidv7()` is a native built-in in PostgreSQL 18+ — no custom function or extension is needed.
- Timestamps: every table has `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` and `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`.
- Soft deletes: use `deleted_at TIMESTAMPTZ` (NULL = active) rather than physical deletes where audit history matters.
- Foreign keys always have an explicit `ON DELETE` action — never leave it implicit.
- Use `NOT NULL` by default; allow `NULL` only when absent value is semantically meaningful.
- Index all foreign key columns. Index columns used in frequent `WHERE` / `ORDER BY` clauses.
- Name indexes: `idx_{table}_{column(s)}`, unique constraints: `uq_{table}_{column(s)}`, foreign keys: `fk_{table}_{referenced_table}`.
- Use `CITEXT` extension (or `LOWER()` functional index) for case-insensitive unique columns like emails.

## Address Conventions

Addresses are stored in US format but structured to support future international expansion:

- `address_line1 TEXT NOT NULL` — street number and street name
- `address_line2 TEXT` — unit, suite, floor (nullable)
- `city TEXT NOT NULL`
- `state TEXT NOT NULL` — 2-letter US state/territory code for now; free-form `TEXT` allows future international subdivision names
- `postal_code TEXT NOT NULL` — stored as `TEXT` to preserve leading zeros and support non-US formats (e.g. `"02134"`, `"SW1A 1AA"`)
- `country TEXT NOT NULL DEFAULT 'US'` — ISO 3166-1 alpha-2 country code

Do **not** use `CHAR(2)` or `CHAR(5)` — use `TEXT` with `CHECK` constraints where format validation is needed.

## Auth Architecture

- **Human users** — authenticated via AWS Cognito. The backend validates Cognito-issued access tokens at login, then establishes a session for the frontend application. Session tokens are stored in the database and used for subsequent requests. `users` records are linked to Cognito by storing the Cognito `sub` (subject UUID) as an immutable external identifier.
- **API clients** — authenticated internally using the OAuth2 client credentials flow. The backend issues and validates tokens directly; credentials (`client_id` / hashed `client_secret`) and issued access tokens are stored in the database.
- **Authorization** — handled entirely internally for both actor types. Roles and permissions are stored in the database and evaluated by the backend on every request.

## Domain Model

This portal manages network infrastructure deployed at residential/mixed-use properties. Core entities:

```
organizations (service provider)  ←─── properties  ←─── units
     │                                     │                │
     │                                     │                └─ subscriptions
     │                                     │
     │                                     └─ network_devices (APs, switches, routers)
     │
     └─── users (Cognito sub → local record)
               │
               └─ roles (resident | property_manager | noc_staff | admin)

     └─── oauth2_clients ←─── oauth2_tokens

service_plans ←─── subscriptions ←─── invoices
                        │
                    (unit or property)

support_tickets (linked to unit + user)
```

Expected tables (not exhaustive):

| Table | Purpose |
|---|---|
| `organizations` | Operator/ISP accounts that manage one or more properties |
| `properties` | A physical building or complex (has a street address) |
| `units` | Individual rentable units within a property (apt #, room #, etc.) |
| `network_devices` | APs, switches, routers, ONUs deployed at a property |
| `users` | All user accounts (residents, property managers, NOC staff); `cognito_sub TEXT UNIQUE NOT NULL` links to Cognito |
| `sessions` | Frontend session tokens issued after Cognito login; used for subsequent authenticated requests |
| `user_roles` | Many-to-many: users ↔ roles (scoped to org or property where applicable) |
| `roles` | Named roles: `resident`, `property_manager`, `noc_staff`, `admin` |
| `oauth2_clients` | OAuth2 client credentials clients (`client_id`, hashed `client_secret`) |
| `oauth2_tokens` | Issued client-credentials access tokens (for revocation / audit) |
| `service_plans` | Available network service tiers (speed, price) |
| `subscriptions` | Unit-level service subscriptions linking a unit to a service plan |
| `invoices` | Billing invoices per subscription / resident |
| `support_tickets` | Resident-submitted support tickets; tracked through resolution |
| `audit_logs` | Immutable append-only event trail |

## Running Migrations

### Embedded (library)

```rust
// In your Rust backend Cargo.toml:
// refinery = { version = "0.9", features = ["tokio-postgres"] }

mod embedded {
    use refinery::embed_migrations;
    embed_migrations!("../portal-schema/migrations");
}

// At startup:
let report = embedded::migrations::runner()
    .run_async(&mut client)
    .await?;
```

### CLI

```bash
export DATABASE_URL="postgres://user:pass@localhost:5432/portal"
refinery migrate -e DATABASE_URL -p ./migrations
```

Install CLI: `cargo install refinery_cli`

## Development Workflow

> **Assumption**: All migrations in this repository should be treated as **unapplied** unless explicitly stated otherwise. This means existing migration files may be freely edited or collapsed rather than requiring additive ALTER migrations to fix them.

1. Create the next migration file: `migrations/V{N}__{description}.sql`
2. Write forward-only SQL (no rollback blocks).
3. Run the smoke-test binary to validate all migrations against a throwaway PostgreSQL 18 container (requires Docker):
   ```bash
   cargo run
   ```
   The binary exits 0 on success and 1 on failure with a descriptive error.
4. Commit the file. The Rust backend will pick it up at next startup (via `embed_migrations!`).
5. To revert a change, create `V{N+1}__revert_{description}.sql`.
