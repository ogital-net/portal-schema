//! Fetches the IEEE OUI CSV and writes a Refinery migration SQL file to stdout.
//!
//! Redirect the output to create (or refresh) the V2 seed migration:
//!
//! ```bash
//! cargo run --bin gen-oui-seed > migrations/V2__oui_seed.sql
//! ```
//!
//! Commit the resulting file alongside the schema changes so the migration
//! runner has all data available at compile time via `embed_migrations!`.

use std::process;

mod oui;

#[tokio::main]
async fn main() {
    match oui::fetch_insert_sql(oui::OUI_CSV_URL).await {
        Ok(sql) => print!("{sql}"),
        Err(e) => {
            eprintln!("ERROR: failed to generate OUI seed SQL: {e}");
            process::exit(1);
        }
    }
}
