//! Lokale Ablage geklonter Stimmen.
//!
//! Eine Stimme besteht aus zwei Dateien im Ablageverzeichnis: `<name>.wav`
//! mit der Referenz-Aufnahme und `<name>.txt` mit ihrem Transkript — dieselbe
//! Konvention wie beim CLI-Aufruf. Damit lässt sich eine Stimme auch von Hand
//! hineinlegen, ohne die WebUI zu benutzen.
//!
//! Das Verzeichnis wird bei jeder Abfrage neu gelesen, nicht beim Start
//! zwischengespeichert: so wirken hineinkopierte Dateien sofort, ohne
//! Neustart.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::tts::Reference;

/// Nur zur Lesbarkeitsprüfung: mit welcher Rate hier dekodiert wird, ist
/// egal — das Ergebnis wird verworfen. Die Rate, die wirklich zählt, kennt
/// nur das geladene Modell ([`crate::tts::Capabilities`]), und dort wird auch
/// dekodiert.
const PRUEF_RATE: u32 = 24_000;

/// Prüfen, ob `wav` eine lesbare WAV-Datei ist.
///
/// Damit ein kaputter Upload als HTTP 400 auffällt und nicht erst mitten im
/// SSE-Stream als Synthese-Fehler.
pub fn validate_wav(wav: &[u8]) -> Result<()> {
    crane::audio::decode_wav(wav, PRUEF_RATE)
        .context("Referenz-Audio ist keine lesbare WAV-Datei")?;
    Ok(())
}

/// Längenlimit für Stimmnamen — hält Dateinamen handhabbar.
const MAX_NAME_LEN: usize = 64;

pub struct VoiceStore {
    dir: PathBuf,
}

impl VoiceStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Namen aller vollständigen Stimmen, sortiert.
    ///
    /// Eine WAV ohne zugehöriges Transkript (oder umgekehrt) wird
    /// übersprungen — das Base-Modell braucht beides, eine halbe Stimme
    /// anzubieten wäre irreführend. Ein fehlendes Verzeichnis ist kein
    /// Fehler, sondern schlicht eine leere Liste.
    pub fn list(&self) -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return Vec::new();
        };

        let mut names: Vec<String> = entries
            .flatten()
            .filter_map(|entry| {
                let path = entry.path();
                if path.extension()? != "wav" {
                    return None;
                }
                let name = path.file_stem()?.to_str()?.to_string();
                self.transcript_path(&name).is_file().then_some(name)
            })
            .collect();

        names.sort();
        names
    }

    /// Eine gespeicherte Stimme als Referenz laden.
    ///
    /// Liefert die WAV-Bytes unverändert — resampled wird erst auf dem
    /// TTS-Thread, der die richtige Rate kennt.
    pub fn load(&self, name: &str) -> Result<Reference> {
        let name = sanitize(name)?;

        let transcript = std::fs::read_to_string(self.transcript_path(&name))
            .with_context(|| format!("Transkript der Stimme '{name}' nicht lesbar"))?;
        let wav = std::fs::read(self.audio_path(&name))
            .with_context(|| format!("Aufnahme der Stimme '{name}' nicht lesbar"))?;

        Ok(Reference { wav, transcript })
    }

    /// Eine Stimme ablegen; eine gleichnamige wird überschrieben.
    ///
    /// `wav` sind die rohen Bytes einer WAV-Datei. Sie werden vor dem
    /// Schreiben einmal dekodiert — was hier nicht lesbar ist, wäre später
    /// beim Sprechen auch nicht lesbar, und dann steckt der Fehler in der
    /// Ablage statt in der Anfrage.
    pub fn save(&self, name: &str, wav: &[u8], transcript: &str) -> Result<String> {
        let name = sanitize(name)?;
        anyhow::ensure!(
            !transcript.trim().is_empty(),
            "Transkript darf nicht leer sein"
        );
        validate_wav(wav)?;

        std::fs::create_dir_all(&self.dir)
            .with_context(|| format!("Stimmen-Verzeichnis nicht anlegbar: {}", self.dir.display()))?;
        std::fs::write(self.audio_path(&name), wav)
            .with_context(|| format!("Aufnahme der Stimme '{name}' nicht schreibbar"))?;
        std::fs::write(self.transcript_path(&name), transcript.trim())
            .with_context(|| format!("Transkript der Stimme '{name}' nicht schreibbar"))?;

        Ok(name)
    }

    /// Eine gespeicherte Stimme löschen.
    ///
    /// Beide Dateien müssen weg — bliebe eine übrig, würde `list` die Stimme
    /// zwar nicht mehr anzeigen, aber ein späteres Speichern unter demselben
    /// Namen träfe auf einen halben Altbestand.
    ///
    /// `Ok(false)`, wenn es die Stimme gar nicht gab; das ist kein Fehler,
    /// sondern für den Aufrufer ein 404.
    pub fn delete(&self, name: &str) -> Result<bool> {
        let name = sanitize(name)?;
        let (audio, transcript) = (self.audio_path(&name), self.transcript_path(&name));
        if !audio.is_file() && !transcript.is_file() {
            return Ok(false);
        }

        for pfad in [audio, transcript] {
            if pfad.is_file() {
                std::fs::remove_file(&pfad)
                    .with_context(|| format!("Datei nicht löschbar: {}", pfad.display()))?;
            }
        }
        Ok(true)
    }

    fn audio_path(&self, name: &str) -> PathBuf {
        self.dir.join(format!("{name}.wav"))
    }

    fn transcript_path(&self, name: &str) -> PathBuf {
        self.dir.join(format!("{name}.txt"))
    }
}

/// Stimmnamen auf unbedenkliche Dateinamen einschränken.
///
/// Der Name kommt aus einer HTTP-Anfrage und landet direkt in einem Pfad —
/// ohne diese Prüfung würde `../../etc/passwd` aus dem Ablageverzeichnis
/// herausführen. Deshalb eine Positivliste statt einer Sperrliste.
fn sanitize(name: &str) -> Result<String> {
    let name = name.trim();
    anyhow::ensure!(!name.is_empty(), "Stimmname darf nicht leer sein");
    anyhow::ensure!(
        name.len() <= MAX_NAME_LEN,
        "Stimmname ist zu lang (max. {MAX_NAME_LEN} Zeichen)"
    );
    anyhow::ensure!(
        name.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
        "Stimmname darf nur Buchstaben, Ziffern, '-' und '_' enthalten"
    );
    Ok(name.to_string())
}

#[cfg(test)]
mod tests {
    use super::{VoiceStore, sanitize};

    #[test]
    fn erlaubt_gewoehnliche_namen() {
        assert_eq!(sanitize(" johannes ").unwrap(), "johannes");
        assert_eq!(sanitize("oma_2024-alt").unwrap(), "oma_2024-alt");
    }

    #[test]
    fn blockt_pfad_ausbrueche() {
        for boese in ["../geheim", "a/b", "a\\b", ".", "..", "a.wav", ""] {
            assert!(sanitize(boese).is_err(), "durchgelassen: {boese:?}");
        }
    }

    #[test]
    fn blockt_zu_lange_namen() {
        assert!(sanitize(&"a".repeat(65)).is_err());
    }

    #[test]
    fn fehlendes_verzeichnis_ist_leere_liste() {
        let store = VoiceStore::new("/gibt/es/nicht/hoffentlich");
        assert!(store.list().is_empty());
    }

    /// Eigenes Verzeichnis je Test — die Tests laufen parallel im selben
    /// Prozess, eine gemeinsame PID reicht als Unterscheidung nicht.
    fn temp_dir(marke: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("voices-test-{}-{marke}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn listet_nur_vollstaendige_stimmen() {
        let dir = temp_dir("liste");
        std::fs::write(dir.join("ganz.wav"), b"x").unwrap();
        std::fs::write(dir.join("ganz.txt"), b"Text").unwrap();
        // Nur Audio, kein Transkript — unbrauchbar fürs Cloning.
        std::fs::write(dir.join("halb.wav"), b"x").unwrap();

        let store = VoiceStore::new(&dir);
        assert_eq!(store.list(), vec!["ganz".to_string()]);

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn loescht_beide_dateien() {
        let dir = temp_dir("loeschen");
        std::fs::write(dir.join("weg.wav"), b"x").unwrap();
        std::fs::write(dir.join("weg.txt"), b"Text").unwrap();

        let store = VoiceStore::new(&dir);
        assert!(store.delete("weg").unwrap());
        assert!(store.list().is_empty());
        assert!(!dir.join("weg.wav").exists());
        assert!(!dir.join("weg.txt").exists());

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn loeschen_meldet_unbekannte_stimme() {
        let dir = temp_dir("unbekannt");
        let store = VoiceStore::new(&dir);
        assert!(!store.delete("gibtsnicht").unwrap());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn loeschen_blockt_pfad_ausbrueche() {
        let store = VoiceStore::new(temp_dir("boese"));
        assert!(store.delete("../../etc/passwd").is_err());
    }
}
