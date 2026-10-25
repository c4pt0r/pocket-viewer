//! HTTPS for --tls, with a self-signed certificate. Browsers let a page use the
//! camera only on https or localhost, so a browser on another machine needs
//! this to share its camera (to the StackChan's screen).
//!
//! The certificate is made once and kept in <config dir>/tls, so a browser
//! that was told to trust it keeps trusting it; it is made again when this
//! machine's addresses change.

use std::net::IpAddr;

use axum_server::tls_rustls::RustlsConfig;

/// The names the certificate is for: localhost and this machine's address on
/// the network.
fn names() -> Vec<String> {
    let mut names = vec!["localhost".to_string(), "127.0.0.1".to_string(), "::1".to_string()];
    // The address the default route leaves from; connecting a UDP socket sends nothing.
    let lan = std::net::UdpSocket::bind("0.0.0.0:0").and_then(|s| s.connect("192.0.2.1:9").and(s.local_addr()));
    if let Ok(a) = lan {
        if !a.ip().is_unspecified() && !a.ip().is_loopback() {
            names.push(a.ip().to_string());
        }
    }
    names
}

pub async fn config() -> anyhow::Result<RustlsConfig> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let dir = crate::config_dir().join("tls");
    let (cert_path, key_path, names_path) = (dir.join("cert.pem"), dir.join("key.pem"), dir.join("names.txt"));
    let names = names();
    let wanted = names.join("\n");
    let current = std::fs::read_to_string(&names_path).unwrap_or_default();
    if current != wanted || !cert_path.exists() || !key_path.exists() {
        let mut params = rcgen::CertificateParams::new(Vec::<String>::new())?;
        params.distinguished_name.push(rcgen::DnType::CommonName, "pocket-viewer");
        for n in &names {
            params.subject_alt_names.push(match n.parse::<IpAddr>() {
                Ok(ip) => rcgen::SanType::IpAddress(ip),
                Err(_) => rcgen::SanType::DnsName(n.clone().try_into()?),
            });
        }
        let key = rcgen::KeyPair::generate()?;
        let cert = params.self_signed(&key)?;
        std::fs::create_dir_all(&dir)?;
        std::fs::write(&cert_path, cert.pem())?;
        write_private(&key_path, key.serialize_pem().as_bytes())?;
        std::fs::write(&names_path, wanted)?;
        crate::log!("made a self-signed certificate for {} in {}", names.join(", "), dir.display());
    }
    Ok(RustlsConfig::from_pem_file(cert_path, key_path).await?)
}

fn write_private(path: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?.write_all(data)
    }
    #[cfg(not(unix))]
    std::fs::write(path, data)
}
