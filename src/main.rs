/// Migration smoke-test binary.
///
/// Spins up a throwaway PostgreSQL 18 container via Testcontainers, runs all
/// Refinery migrations from the `migrations/` directory, and exits 0 on
/// success or 1 on failure.
///
/// Prerequisites
/// -------------
/// - Docker must be installed and the daemon must be running.  The binary
///   checks for both before attempting to start a container.
/// - The `migrations/` directory is embedded at compile time via
///   `refinery::embed_migrations!`, so no runtime path resolution is needed.
use std::process;

use refinery::Runner;
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{GenericImage, ImageExt};
use tokio_postgres::NoTls;

// Embed every file under migrations/ at compile time.
// Refinery will sort them by version number and apply in order.
mod embedded {
    use refinery::embed_migrations;
    embed_migrations!("migrations");
}

#[tokio::main]
async fn main() {
    println!("=== portal-schema migration test ===\n");

    check_docker_available();

    println!("[1/3] Starting PostgreSQL 18 container...");

    // Use the official postgres:18 image.  Testcontainers will pull it on first
    // run; subsequent runs use the local cache.
    let postgres_image = GenericImage::new("postgres", "18")
        .with_wait_for(WaitFor::message_on_stderr(
            "database system is ready to accept connections",
        ))
        .with_env_var("POSTGRES_USER", "portal")
        .with_env_var("POSTGRES_PASSWORD", "portal")
        .with_env_var("POSTGRES_DB", "portal_test");

    let container = match postgres_image.start().await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ERROR: Failed to start PostgreSQL container: {e}");
            eprintln!(
                "Make sure Docker is running and the postgres:18 image is accessible."
            );
            process::exit(1);
        }
    };

    let host = container.get_host().await.unwrap_or_else(|e| {
        eprintln!("ERROR: Could not determine container host: {e}");
        process::exit(1);
    });

    let port = container
        .get_host_port_ipv4(5432.tcp())
        .await
        .unwrap_or_else(|e| {
            eprintln!("ERROR: Could not determine container port: {e}");
            process::exit(1);
        });

    println!("      Container ready at {host}:{port}");

    // ---------------------------------------------------------------------------
    // Connect (with retries — the port may not be accepting connections the
    // instant Testcontainers signals "ready")
    // ---------------------------------------------------------------------------
    println!("[2/3] Connecting to database...");

    let connection_string =
        format!("host={host} port={port} user=portal password=portal dbname=portal_test");

    let (mut client, connection) = {
        let mut last_err = None;
        let mut result = None;
        for attempt in 1..=10 {
            match tokio_postgres::connect(&connection_string, NoTls).await {
                Ok(pair) => {
                    result = Some(pair);
                    break;
                }
                Err(e) => {
                    if attempt < 10 {
                        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    }
                    last_err = Some(e);
                }
            }
        }
        result.unwrap_or_else(|| {
            eprintln!(
                "ERROR: Failed to connect to PostgreSQL after 10 attempts: {}",
                last_err.unwrap()
            );
            process::exit(1);
        })
    };

    // Drive the connection in a background task; if it errors we surface it
    // after the migrations run.
    let conn_handle = tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("WARNING: PostgreSQL connection error: {e}");
        }
    });

    // ---------------------------------------------------------------------------
    // Run migrations
    // ---------------------------------------------------------------------------
    println!("[3/3] Applying migrations...\n");

    let runner: Runner = embedded::migrations::runner();

    match runner.run_async(&mut client).await {
        Ok(report) => {
            let applied: Vec<_> = report.applied_migrations().to_vec();
            if applied.is_empty() {
                println!("  (no migrations to apply — already up to date)");
            } else {
                for m in &applied {
                    println!("  ✓  V{}  {}", m.version(), m.name());
                }
            }
            println!("\n✅  All migrations applied successfully ({} total).", applied.len());
        }
        Err(e) => {
            eprintln!("\n❌  Migration failed:\n\n{e}");
            // Abort the connection task cleanly before exiting.
            conn_handle.abort();
            process::exit(1);
        }
    }

    conn_handle.abort();

    // `container` is dropped here, which stops and removes the Docker container.
    drop(container);
}

/// Verify that the `docker` CLI is on PATH and the daemon is reachable.
///
/// Exits the process with a helpful message if either check fails so the user
/// gets a clear error rather than a cryptic container-startup failure later.
fn check_docker_available() {
    // Check 1: `docker` binary exists on PATH.
    match std::process::Command::new("docker")
        .arg("--version")
        .output()
    {
        Ok(output) if output.status.success() => {
            let version = String::from_utf8_lossy(&output.stdout);
            println!("Docker CLI : {}", version.trim());
        }
        Ok(output) => {
            eprintln!(
                "ERROR: `docker --version` exited with status {}.",
                output.status
            );
            process::exit(1);
        }
        Err(e) => {
            eprintln!("ERROR: `docker` not found on PATH: {e}");
            eprintln!("Install Docker Desktop (https://www.docker.com/products/docker-desktop)");
            eprintln!("and ensure the `docker` CLI is available before running this binary.");
            process::exit(1);
        }
    }

    // Check 2: Docker daemon is reachable.
    match std::process::Command::new("docker").arg("info").output() {
        Ok(output) if output.status.success() => {
            println!("Docker daemon: reachable\n");
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            eprintln!("ERROR: Docker daemon is not running or not accessible.");
            if !stderr.is_empty() {
                eprintln!("       {}", stderr.trim());
            }
            eprintln!("Start Docker Desktop and try again.");
            process::exit(1);
        }
        Err(e) => {
            eprintln!("ERROR: Failed to run `docker info`: {e}");
            process::exit(1);
        }
    }
}
