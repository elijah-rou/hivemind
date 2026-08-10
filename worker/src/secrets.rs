use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::message::EnvEntry;

const CACHE_TTL: Duration = Duration::from_secs(300); // 5 minutes

struct CachedSecret {
    value: String,
    fetched_at: Instant,
}

pub struct SecretResolver {
    doppler_token: Option<String>,
    doppler_project: Option<String>,
    doppler_config: Option<String>,
    cache: HashMap<String, CachedSecret>,
}

impl SecretResolver {
    pub fn new() -> Self {
        Self {
            doppler_token: std::env::var("DOPPLER_TOKEN").ok(),
            doppler_project: std::env::var("DOPPLER_PROJECT").ok(),
            doppler_config: std::env::var("DOPPLER_CONFIG").ok(),
            cache: HashMap::new(),
        }
    }

    /// Resolve a single plain value or Doppler secret name.
    pub fn resolve_plain_or_secret(&mut self, value: &str, is_secret_ref: bool) -> Option<String> {
        if is_secret_ref {
            if value.is_empty() {
                return None;
            }
            self.resolve_secret(value)
        } else {
            Some(value.to_string())
        }
    }

    /// Resolve env entries: plain values pass through, secret refs are fetched from Doppler.
    pub fn resolve(&mut self, entries: &[EnvEntry]) -> Vec<(String, String)> {
        entries
            .iter()
            .filter_map(|entry| {
                let value = if entry.is_secret_ref {
                    self.resolve_secret(&entry.value)
                } else {
                    Some(entry.value.clone())
                };
                value.map(|v| (entry.name.clone(), v))
            })
            .collect()
    }

    fn resolve_secret(&mut self, secret_name: &str) -> Option<String> {
        // Check cache first
        if let Some(cached) = self.cache.get(secret_name) {
            if cached.fetched_at.elapsed() < CACHE_TTL {
                return Some(cached.value.clone());
            }
        }

        let token = self.doppler_token.as_ref()?;
        let project = self.doppler_project.as_deref().unwrap_or("default");
        let config = self.doppler_config.as_deref().unwrap_or("prd");

        let url = format!(
            "https://api.doppler.com/v3/configs/config/secret?project={project}&config={config}&name={secret_name}"
        );

        let result = ureq::get(&url)
            .set("Authorization", &format!("Bearer {token}"))
            .call();

        match result {
            Ok(resp) => {
                let body: serde_json::Value = resp.into_json().ok()?;
                let value = body["value"]["raw"].as_str()?.to_string();

                self.cache.insert(
                    secret_name.to_string(),
                    CachedSecret {
                        value: value.clone(),
                        fetched_at: Instant::now(),
                    },
                );

                Some(value)
            }
            Err(e) => {
                eprintln!("doppler secret fetch failed for {secret_name}: {e}");
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_env_vars_pass_through() {
        let mut resolver = SecretResolver::new();
        let entries = vec![
            EnvEntry {
                name: "FOO".into(),
                value: "bar".into(),
                is_secret_ref: false,
            },
            EnvEntry {
                name: "BAZ".into(),
                value: "qux".into(),
                is_secret_ref: false,
            },
        ];

        let resolved = resolver.resolve(&entries);
        assert_eq!(resolved.len(), 2);
        assert_eq!(resolved[0], ("FOO".into(), "bar".into()));
        assert_eq!(resolved[1], ("BAZ".into(), "qux".into()));
    }

    #[test]
    fn secret_ref_without_token_is_skipped() {
        let mut resolver = SecretResolver::new();
        // No DOPPLER_TOKEN set in test env
        resolver.doppler_token = None;

        let entries = vec![EnvEntry {
            name: "SECRET".into(),
            value: "my-secret".into(),
            is_secret_ref: true,
        }];

        let resolved = resolver.resolve(&entries);
        assert_eq!(resolved.len(), 0); // skipped because no token
    }
}
