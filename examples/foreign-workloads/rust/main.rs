// A foreign (non-Kyte) Rust HTTP server using only std: reads $PORT and echoes it plus FOO.
// Build: rustc -O -o app main.rs   (see ../build.sh) -- no cargo/crates needed.
use std::io::Write;
use std::net::TcpListener;

fn main() {
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let foo = std::env::var("FOO").unwrap_or_else(|_| "(unset)".to_string());
    let listener = TcpListener::bind(format!("0.0.0.0:{}", port)).expect("bind");
    eprintln!("foreign Rust server listening on PORT={} FOO={}", port, foo);
    for stream in listener.incoming() {
        if let Ok(mut conn) = stream {
            let body = format!("RUST-OK port={} FOO={}\n", port, foo);
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = conn.write_all(resp.as_bytes());
        }
    }
}
