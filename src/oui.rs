//! OUI seed-data generator.
//!
//! Downloads the IEEE OUI CSV, parses every row, and formats the data as
//! batched SQL `INSERT` statements targeting the `oui_assignments` table.
//! The output string is ready to be written directly to a Refinery migration
//! file (e.g. `migrations/V2__oui_seed.sql`).
//!
//! # Usage
//!
//! ```bash
//! cargo run --bin gen-oui-seed > migrations/V2__oui_seed.sql
//! ```

/// Canonical IEEE OUI CSV download URL.
pub const OUI_CSV_URL: &str = "https://standards-oui.ieee.org/oui/oui.csv";

/// Number of `VALUES` rows per `INSERT` statement.
///
/// Kept at 500 to stay well under PostgreSQL's parameter limit while still
/// reducing round-trip overhead during migration execution.
const INSERT_BATCH_SIZE: usize = 500;

/// Download the OUI CSV from `url`, parse it, and return a SQL string of
/// batched `INSERT INTO oui_assignments` statements.
///
/// The returned string may be written directly to a Refinery migration file.
pub async fn fetch_insert_sql(
    url: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let response = reqwest::get(url).await?.error_for_status()?;
    let body = response.text().await?;
    build_insert_sql(&body)
}

/// Parse OUI CSV text and return batched `INSERT` statements for both
/// `oui_organizations` and `oui_assignments`.
///
/// Organization names are deduplicated using a case-insensitive normalized key.
/// A `BTreeMap` keyed on the normalized name keeps orgs in alphabetical order
/// so the emitted rows and their sequential ids are stable and sorted.
/// Each org is assigned an explicit integer id so the assignment inserts can
/// reference it directly without a subquery join.
///
/// Separated from [`fetch_insert_sql`] so it can be tested without network
/// access.
pub fn build_insert_sql(
    csv_text: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let mut reader = csv::Reader::from_reader(csv_text.as_bytes());

    // Pass 1: collect raw rows and deduplicate orgs.
    //
    // org_map: normalized_key -> canonical_name (first form seen wins)
    // Sorted by BTreeMap key = sorted alphabetically by normalized name.
    let mut org_map: std::collections::BTreeMap<String, String> =
        std::collections::BTreeMap::new();

    // (assignment macaddr literal, registry, normalized org key)
    let mut raw_rows: Vec<(String, String, String)> = Vec::with_capacity(32_768);

    for result in reader.records() {
        let record = result?;

        let registry = record.get(0).unwrap_or("").trim().to_string();
        let raw = record.get(1).unwrap_or("").trim().to_uppercase();
        let organization = record.get(2).unwrap_or("").trim().to_string();

        if raw.is_empty() || organization.is_empty() {
            continue;
        }

        // Format as a MACADDR literal with the last 3 bytes zeroed so that
        // `trunc(macaddr)` lookups match directly.
        let assignment = match oui_hex_to_macaddr(&raw) {
            Some(m) => m,
            None => continue, // skip malformed entries
        };

        let org_key = normalize_org(&organization);
        // Normalize all-caps names to title case before storing.
        let organization = if is_all_caps(&organization) {
            to_title_case(&organization)
        } else {
            organization
        };
        // First canonical form wins; subsequent variants are silently dropped.
        org_map.entry(org_key.clone()).or_insert(organization);
        raw_rows.push((assignment, registry, org_key));
    }

    // Pass 2: assign 1-based sequential ids in BTreeMap (alphabetical) order.
    let id_map: std::collections::HashMap<String, usize> = org_map
        .keys()
        .enumerate()
        .map(|(i, k)| (k.clone(), i + 1))
        .collect();

    // Sorted org list: (id, canonical_name)
    let orgs_sorted: Vec<(usize, &str)> = org_map
        .values()
        .enumerate()
        .map(|(i, name)| (i + 1, name.as_str()))
        .collect();

    // Resolve assignment rows to their final org ids.
    let rows: Vec<(String, String, usize)> = raw_rows
        .into_iter()
        .map(|(assignment, registry, key)| {
            let org_id = id_map[&key];
            (assignment, registry, org_id)
        })
        .collect();

    let total_orgs = orgs_sorted.len();
    let total_assignments = rows.len();

    let mut out = String::with_capacity(total_assignments * 60 + total_orgs * 50 + 4096);

    out.push_str("-- OUI seed data\n");
    out.push_str(&format!(
        "-- {total_orgs} unique organizations, {total_assignments} assignments\n"
    ));
    out.push_str("-- Source:    https://standards-oui.ieee.org/oui/oui.csv\n");
    out.push_str("-- Generator: cargo run --bin gen-oui-seed > migrations/V2__oui_seed.sql\n");
    out.push_str("-- Re-run this command whenever you want to refresh the OUI data.\n\n");

    // -------------------------------------------------------------------------
    // DDL — drop in reverse-FK order, then recreate
    // -------------------------------------------------------------------------
    out.push_str("-- Drop existing tables (safe to re-run)\n");
    out.push_str("DROP TABLE IF EXISTS oui_assignments;\n");
    out.push_str("DROP TABLE IF EXISTS oui_organizations;\n\n");

    out.push_str("-- oui_organizations: deduplicated vendor/manufacturer registry\n");
    out.push_str("CREATE TABLE oui_organizations (\n");
    out.push_str("    id      SERIAL      PRIMARY KEY,\n");
    out.push_str("    -- CITEXT gives case-insensitive storage and comparisons for free\n");
    out.push_str("    name    CITEXT      NOT NULL,\n");
    out.push_str("    CONSTRAINT uq_oui_organizations_name UNIQUE (name)\n");
    out.push_str(");\n\n");

    out.push_str("-- oui_assignments: OUI -> organization FK mapping\n");
    out.push_str("-- Lookup pattern: WHERE assignment = trunc(some_macaddr)\n");
    out.push_str("CREATE TABLE oui_assignments (\n");
    out.push_str("    id              SERIAL      PRIMARY KEY,\n");
    out.push_str("    assignment      MACADDR     NOT NULL,\n");
    out.push_str("    registry        TEXT        NOT NULL,\n");
    out.push_str("    organization_id INTEGER     NOT NULL,\n");
    out.push_str("    CONSTRAINT uq_oui_assignments_assignment UNIQUE (assignment),\n");
    out.push_str("    CONSTRAINT fk_oui_assignments_organization\n");
    out.push_str("        FOREIGN KEY (organization_id)\n");
    out.push_str("        REFERENCES oui_organizations (id)\n");
    out.push_str("        ON DELETE RESTRICT\n");
    out.push_str(");\n\n");

    out.push_str("CREATE INDEX idx_oui_assignments_assignment      ON oui_assignments (assignment);\n");
    out.push_str("CREATE INDEX idx_oui_assignments_organization_id ON oui_assignments (organization_id);\n");
    out.push_str("-- Trigram index enables fast ILIKE / similarity searches on org name\n");
    out.push_str("CREATE EXTENSION IF NOT EXISTS pg_trgm;\n");
    out.push_str("CREATE INDEX idx_oui_organizations_name_trgm ON oui_organizations USING GIN (name gin_trgm_ops);\n\n");

    // -------------------------------------------------------------------------
    // oui_organizations — explicit ids so assignment rows can reference them
    // by integer directly, avoiding a subquery per batch.
    // -------------------------------------------------------------------------
    out.push_str("-- Organizations\n");
    for (chunk_idx, chunk) in orgs_sorted.chunks(INSERT_BATCH_SIZE).enumerate() {
        let start_id = chunk_idx * INSERT_BATCH_SIZE + 1;
        out.push_str("INSERT INTO oui_organizations (id, name) VALUES\n");
        let last = chunk.len() - 1;
        for (i, (id, name)) in chunk.iter().enumerate() {
            let _ = start_id; // id is already correct from orgs_sorted
            let trailing = if i == last { "" } else { "," };
            out.push_str(&format!("    ({}, '{}'){}\n", id, escape_sql(name), trailing));
        }
        out.push_str("ON CONFLICT DO NOTHING;\n\n");
    }
    // Advance the sequence past the explicitly-seeded ids so future
    // application inserts don't collide.
    out.push_str(&format!(
        "SELECT setval('oui_organizations_id_seq', {total_orgs}, true);\n\n"
    ));

    // -------------------------------------------------------------------------
    // oui_assignments
    // -------------------------------------------------------------------------
    out.push_str("-- Assignments\n");
    for chunk in rows.chunks(INSERT_BATCH_SIZE) {
        out.push_str(
            "INSERT INTO oui_assignments (assignment, registry, organization_id) VALUES\n",
        );
        let last = chunk.len() - 1;
        for (i, (assignment, registry, org_id)) in chunk.iter().enumerate() {
            let trailing = if i == last { "" } else { "," };
            out.push_str(&format!(
                "    ('{}', '{}', {}){}\n",
                escape_sql(assignment),
                escape_sql(registry),
                org_id,
                trailing,
            ));
        }
        out.push_str("ON CONFLICT (assignment) DO NOTHING;\n\n");
    }

    Ok(out)
}

/// Returns `true` if every alphabetic character in `s` is uppercase and
/// there is at least one alphabetic character.  Non-alphabetic characters
/// (digits, punctuation, spaces) are ignored.
fn is_all_caps(s: &str) -> bool {
    let mut has_alpha = false;
    for c in s.chars() {
        if c.is_alphabetic() {
            if c.is_lowercase() {
                return false;
            }
            has_alpha = true;
        }
    }
    has_alpha
}

/// Convert a string to title case: within each whitespace-separated token the
/// first alphabetic character is uppercased and all subsequent alphabetic
/// characters are lowercased; non-alphabetic characters are preserved.
///
/// Multiple/Unicode spaces are collapsed by the whitespace split.
fn to_title_case(s: &str) -> String {
    s.split_whitespace()
        .map(|word| {
            let mut out = String::with_capacity(word.len());
            // Reset to uppercase after any non-alphabetic separator within a
            // token so "CO.,LTD" becomes "Co.,Ltd" rather than "Co.,ltd".
            let mut next_upper = true;
            for c in word.chars() {
                if c.is_alphabetic() {
                    if next_upper {
                        out.extend(c.to_uppercase());
                        next_upper = false;
                    } else {
                        out.extend(c.to_lowercase());
                    }
                } else {
                    out.push(c);
                    next_upper = true;
                }
            }
            out
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Compute a normalized deduplication key for an organization name.
///
/// Two names that differ only by punctuation, capitalization, Unicode
/// whitespace variants (non-breaking spaces, en-spaces, etc.), or trailing
/// separators will produce the same key.  The canonical stored form is always
/// the *first* name seen for a given key.
///
/// Normalization steps:
/// 1. Map every Unicode whitespace character to an ASCII space.
/// 2. Lowercase all characters.
/// 3. Drop stylistic punctuation: `. , - ' / \ & ;`
/// 4. Collapse runs of spaces and trim.
fn normalize_org(name: &str) -> String {
    let mut buf = String::with_capacity(name.len());
    for c in name.chars() {
        if c.is_whitespace() {
            buf.push(' ');
        } else if matches!(c, '.' | ',' | '-' | '\'' | '/' | '\\' | '&' | ';') {
            // skip stylistic separators
        } else {
            for lc in c.to_lowercase() {
                buf.push(lc);
            }
        }
    }
    // split_whitespace collapses runs and trims in one pass
    buf.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Convert a 6-character uppercase hex OUI string (e.g. `"286FB9"`) to the
/// PostgreSQL `MACADDR` literal format with the last 3 bytes zeroed
/// (e.g. `"28:6f:b9:00:00:00"`).
///
/// Returns `None` if `oui` is not exactly 6 hex characters.
fn oui_hex_to_macaddr(oui: &str) -> Option<String> {
    if oui.len() != 6 || !oui.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!(
        "{:}:{:}:{:}:00:00:00",
        oui[0..2].to_lowercase(),
        oui[2..4].to_lowercase(),
        oui[4..6].to_lowercase(),
    ))
}

/// Escape a value for use inside a SQL single-quoted string literal.
///
/// Replaces every `'` with `''` per the SQL standard. The OUI CSV source
/// (ieee.org) is trusted input, but correct escaping is applied regardless.
fn escape_sql(s: &str) -> String {
    s.replace('\'', "''")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_CSV: &str = "\
Registry,Assignment,Organization Name,Organization Address
MA-L,286FB9,\"Nokia Shanghai Bell Co., Ltd.\",\"No.388 Ning Qiao Road  CN\"
MA-L,08EA44,Extreme Networks Headquarters,2121 RDU Center Drive  US
MA-S,70B3D5,IEEE Registration Authority,445 Hoes Lane  US
";

    #[test]
    fn parses_sample_csv() {
        let sql = build_insert_sql(SAMPLE_CSV).unwrap();

        // DDL preamble
        assert!(sql.contains("DROP TABLE IF EXISTS oui_assignments;"));
        assert!(sql.contains("DROP TABLE IF EXISTS oui_organizations;"));
        assert!(sql.contains("CREATE TABLE oui_organizations"));
        assert!(sql.contains("CREATE TABLE oui_assignments"));
        assert!(sql.contains("REFERENCES oui_organizations (id)"));
        assert!(sql.contains("pg_trgm"));
        assert!(sql.contains("idx_oui_organizations_name_trgm"));

        // Orgs are sorted alphabetically by normalized name:
        //   "extreme networks headquarters" -> 1
        //   "ieee registration authority"   -> 2
        //   "nokia shanghai bell co ltd"    -> 3
        assert!(sql.contains("INSERT INTO oui_organizations (id, name)"));
        assert!(sql.contains("(1, 'Extreme Networks Headquarters')"));
        assert!(sql.contains("(2, 'IEEE Registration Authority')"));
        assert!(sql.contains("(3, 'Nokia Shanghai Bell Co., Ltd.')"));
        assert!(sql.contains("setval('oui_organizations_id_seq', 3, true)"));

        // Assignments reference the alphabetically-assigned org ids
        assert!(sql.contains("INSERT INTO oui_assignments (assignment, registry, organization_id)"));
        assert!(sql.contains("'28:6f:b9:00:00:00', 'MA-L', 3"));
        assert!(sql.contains("'08:ea:44:00:00:00', 'MA-L', 1"));
        assert!(sql.contains("'70:b3:d5:00:00:00', 'MA-S', 2"));

        // Raw hex must not appear
        assert!(!sql.contains("'286FB9'"), "raw hex must not appear in output");

        assert!(sql.contains("ON CONFLICT (assignment) DO NOTHING;"));
    }

    #[test]
    fn deduplicates_organizations_case_insensitively() {
        let csv = "\
Registry,Assignment,Organization Name,Organization Address
MA-L,AABBCC,Widget Corp,addr
MA-L,DDEEFF,WIDGET CORP,addr
MA-L,112233,widget corp,addr
";
        let sql = build_insert_sql(csv).unwrap();

        // Only one org row — first canonical form wins
        assert!(sql.contains("(1, 'Widget Corp')"));
        assert!(!sql.contains("(2,"), "only one unique org should be emitted");
        assert!(sql.contains("setval('oui_organizations_id_seq', 1, true)"));

        // All three assignments map to org_id 1
        assert!(sql.contains("'aa:bb:cc:00:00:00', 'MA-L', 1"));
        assert!(sql.contains("'dd:ee:ff:00:00:00', 'MA-L', 1"));
        assert!(sql.contains("'11:22:33:00:00:00', 'MA-L', 1"));
    }

    #[test]
    fn deduplicates_organizations_punctuation_variants() {
        // Mirrors real-world IEEE CSV patterns identified in the dataset:
        //   trailing dot, comma before suffix, non-breaking space, double space, all-caps
        let csv = "\
Registry,Assignment,Organization Name,Organization Address
MA-L,AABBCC,\"Cisco Systems\u{00a0}Inc.\",addr
MA-L,DDEEFF,CISCO SYSTEMS INC,addr
MA-L,112233,\"Cisco Systems, Inc.\",addr
MA-L,223344,Cisco Systems Inc,addr
MA-L,334455,Cisco Systems  Inc.,addr
";
        let sql = build_insert_sql(csv).unwrap();

        // Only the first canonical form should be stored
        assert!(sql.contains("(1, 'Cisco Systems\u{00a0}Inc.')"));
        assert!(!sql.contains("(2,"), "all variants must collapse to one org");
        assert!(sql.contains("setval('oui_organizations_id_seq', 1, true)"));

        // Every assignment maps to org_id 1
        for mac in &["aa:bb:cc", "dd:ee:ff", "11:22:33", "22:33:44", "33:44:55"] {
            assert!(
                sql.contains(&format!("'{mac}:00:00:00', 'MA-L', 1")),
                "{mac} should map to org_id 1"
            );
        }
    }

    #[test]
    fn normalize_org_handles_unicode_whitespace() {
        // Non-breaking space and en-space should collapse to the same key as regular space
        let nbsp = normalize_org("Foo\u{00a0}Bar");
        let ensp = normalize_org("Foo\u{2002}Bar");
        let norm = normalize_org("Foo Bar");
        assert_eq!(nbsp, norm);
        assert_eq!(ensp, norm);
    }

    #[test]
    fn normalizes_all_caps_to_title_case() {
        let csv = "\
Registry,Assignment,Organization Name,Organization Address
MA-L,AABBCC,CISCO SYSTEMS INC,addr
MA-L,DDEEFF,Samsung Electronics Co.,addr
MA-L,112233,\"HUAWEI TECHNOLOGIES CO.,LTD\",addr
MA-L,223344,already Title Case Inc.,addr
MA-L,334455,lower case corp,addr
";
        let sql = build_insert_sql(csv).unwrap();

        // All-caps names are title-cased
        assert!(sql.contains("'Cisco Systems Inc'"), "all-caps should become title case");
        assert!(sql.contains("'Huawei Technologies Co.,Ltd'"), "all-caps with punctuation");

        // Mixed / lower case names are left untouched
        assert!(sql.contains("'Samsung Electronics Co.'"), "mixed case unchanged");
        assert!(sql.contains("'already Title Case Inc.'"), "already title case unchanged");
        assert!(sql.contains("'lower case corp'"), "lowercase unchanged");
    }

    #[test]
    fn is_all_caps_checks() {
        assert!(is_all_caps("CISCO"));
        assert!(is_all_caps("CISCO SYSTEMS, INC."));
        assert!(!is_all_caps("Cisco"));
        assert!(!is_all_caps("cisco"));
        assert!(!is_all_caps("CiSco"));
        // Non-alpha only — no alphabetic chars, should return false
        assert!(!is_all_caps("123"));
        assert!(!is_all_caps(""));
    }

    #[test]
    fn to_title_case_converts() {
        assert_eq!(to_title_case("CISCO SYSTEMS, INC."), "Cisco Systems, Inc.");
        assert_eq!(to_title_case("HUAWEI TECHNOLOGIES CO.,LTD"), "Huawei Technologies Co.,Ltd");
        // Collapses extra spaces
        assert_eq!(to_title_case("WIDGET  CORP"), "Widget Corp");
        // Non-alpha separator within a token resets capitalizer
        assert_eq!(to_title_case("CO.,LTD"), "Co.,Ltd");
    }

    #[test]
    fn oui_hex_to_macaddr_formats_correctly() {
        assert_eq!(
            oui_hex_to_macaddr("286FB9"),
            Some("28:6f:b9:00:00:00".to_string())
        );
        assert_eq!(
            oui_hex_to_macaddr("08EA44"),
            Some("08:ea:44:00:00:00".to_string())
        );
        // Too short
        assert_eq!(oui_hex_to_macaddr("286F"), None);
        // Non-hex character
        assert_eq!(oui_hex_to_macaddr("GGGGGG"), None);
    }

    #[test]
    fn escapes_single_quotes() {
        assert_eq!(escape_sql("O'Brien"), "O''Brien");
        assert_eq!(escape_sql("Nokia Shanghai Bell Co., Ltd."), "Nokia Shanghai Bell Co., Ltd.");
    }

    #[test]
    fn skips_empty_rows() {
        let csv = "Registry,Assignment,Organization Name,Organization Address\nMA-L,,Empty Assignment,addr\n";
        let sql = build_insert_sql(csv).unwrap();
        // DDL is always emitted, but no INSERT rows for a skipped record
        assert!(sql.contains("CREATE TABLE oui_organizations"));
        assert!(!sql.contains("INSERT INTO oui_organizations"));
        assert!(!sql.contains("INSERT INTO oui_assignments"));
    }
}
