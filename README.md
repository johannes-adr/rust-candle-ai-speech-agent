# Vorleser

Mac-App, die PDFs und Texte in MP3-Hörbücher verwandelt. Vorgelesen wird mit
Qwen3-TTS, lokal auf Apple Silicon: fertige Stimmen, beschriebene Stimmen oder
die eigene, geklonte Stimme, in 10 Sprachen. Die Bedienung ist so einfach, dass
eine Oma sie ohne Hilfe schafft.

**Status:** Planung abgeschlossen, Umsetzung beginnt. Siehe [PLAN.md](PLAN.md).
Das frühere Rust/Candle-Projekt liegt auf `main`.

## Weiterarbeiten mit Claude Code auf dem Mac

Voraussetzungen: macOS 26, Xcode 26 (App Store), Homebrew, Claude Code.

```bash
brew install xcodegen
git clone https://github.com/johannes-adr/rust-candle-ai-speech-agent.git vorleser
cd vorleser
git checkout claude/vorleser
claude
```

Erste Nachricht an Claude:

> Lies CLAUDE.md und PLAN.md. Starte mit Phase 0, Spike S1: Lege ein minimales
> Swift-Package an, lade Qwen3-TTS 1.7B-Base in 4-bit und 8-bit über
> mlx-audio-swift und miss auf diesem M4 RTF, Spitzenspeicher und den
> Klon-Overhead pro Aufruf, jeweils auf Deutsch und Portugiesisch. Schreib die
> Ergebnisse nach docs/spikes/S1-engine.md und leg die Hörproben für mich in
> spike-output/.
