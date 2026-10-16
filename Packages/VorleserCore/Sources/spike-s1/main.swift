// Spike S1: Engine-Messung (RTF, Speicher, Ladezeit, Klon-Overhead).
//
//   spike-s1 refs  --out DIR                     VoiceDesign-Referenzen (de, pt) erzeugen
//   spike-s1 bench --bits 4|8 --out DIR [--interval 0.32] [--langs de,pt]
//
// Nur für Messungen; keine App-Logik.
import AVFoundation
import Darwin
import Foundation
import Projects
import VorleserSpeech
import TextPrep

// MARK: Hilfen

func arg(_ name: String, default def: String? = nil) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return def
}

/// phys_footprint aktuell und Spitze (Ledger) in GB.
func footprintGB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1e9, Double(info.ledger_phys_footprint_peak) / 1e9)
}

func writeWav(_ samples: [Float], rate: Double, to url: URL) throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buf)
}

struct Check { var nan = 0; var peak: Float = 0; var rms: Float = 0; var trailingSilence = 0.0 }
func check(_ s: [Float], rate: Double) -> Check {
    var c = Check()
    var sum: Double = 0
    for v in s {
        if !v.isFinite { c.nan += 1; continue }
        c.peak = max(c.peak, abs(v)); sum += Double(v * v)
    }
    c.rms = Float((sum / Double(max(s.count, 1))).squareRoot())
    var n = 0
    for v in s.reversed() { if abs(v) < 0.005 { n += 1 } else { break } }
    c.trailingSilence = Double(n) / rate
    return c
}

func f(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }

let spikeProject = UUID(uuidString: "00000000-0000-0000-0000-0000000000S1".replacingOccurrences(of: "S1", with: "51"))!

// MARK: Texte

struct LangSet { let lang: Language; let description: String; let refText: String; let chunks: [String] }

let sets: [LangSet] = [
    LangSet(
        lang: .de,
        description: "A calm, warm elderly woman's voice with a clear native German accent, speaking clearly, like a gentle storyteller.",
        refText: "Guten Tag, ich bin Ihre Vorleserin. Ich lese Ihnen heute gerne einen Brief oder eine Geschichte vor, ganz in Ruhe.",
        chunks: [
            "Der Herbst kam in diesem Jahr früher als erwartet. Schon Ende September färbten sich die Blätter der alten Linde vor dem Haus gelb und rot, und jeden Morgen lag ein dünner Nebel über den Wiesen. Anna stand am Fenster, hielt ihre Tasse Tee in beiden Händen und sah zu, wie der Postbote langsam die Straße herunterkam.",
            "Er brachte einen Brief, auf den sie schon seit Wochen gewartet hatte. Der Umschlag war dick und trug eine fremde Briefmarke. Sie setzte sich an den Küchentisch, öffnete ihn vorsichtig mit dem Messer und begann zu lesen. Mit jeder Zeile wurde ihr Lächeln breiter, denn die Nachricht war besser, als sie zu hoffen gewagt hatte.",
            "Am Nachmittag rief sie ihre Schwester an und erzählte ihr alles ganz genau. Sie sprachen fast eine Stunde miteinander, lachten viel und beschlossen, im Winter gemeinsam zu verreisen. Als das Gespräch zu Ende war, zündete Anna eine Kerze an, stellte sie auf das Fensterbrett und freute sich schon auf die kommenden Monate.",
        ]),
    LangSet(
        lang: .pt,
        description: "A calm, warm elderly woman's voice with a clear native Brazilian Portuguese accent, speaking clearly, like a gentle storyteller.",
        refText: "Bom dia, eu sou a sua leitora. Hoje vou ler para você uma carta ou uma história, com muita calma.",
        chunks: [
            "O outono chegou mais cedo neste ano. Já no fim de setembro as folhas da velha tília em frente à casa ficaram amarelas e vermelhas, e todas as manhãs uma névoa fina cobria os campos. Ana ficou parada junto à janela, segurando a xícara de chá com as duas mãos, e viu o carteiro descer devagar a rua.",
            "Ele trazia uma carta que ela esperava havia semanas. O envelope era grosso e tinha um selo estrangeiro. Ela sentou-se à mesa da cozinha, abriu-o com cuidado usando a faca e começou a ler. A cada linha o seu sorriso ficava maior, porque a notícia era melhor do que ela tinha ousado esperar.",
            "À tarde ela telefonou para a irmã e contou tudo com muitos detalhes. Conversaram quase uma hora, riram bastante e decidiram viajar juntas no inverno. Quando a conversa terminou, Ana acendeu uma vela, colocou-a no parapeito da janela e ficou feliz pensando nos meses que viriam.",
        ]),
]

// MARK: Befehle

func runRefs(out: URL) async throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let engine = MLXQwenEngine(bits: .four)
    let t0 = Date()
    try await engine.load(.voiceDesign)
    print("VoiceDesign-4bit geladen in \(f(Date().timeIntervalSince(t0))) s, Footprint \(f(footprintGB().now)) GB")
    let rate = await engine.sampleRate
    for s in sets {
        let samples = try await engine.design(description: s.description, sampleText: s.refText, language: s.lang, seed: 1234)
        let stats = await engine.lastStats
        let c = check(samples, rate: rate)
        let url = out.appendingPathComponent("ref-\(s.lang.rawValue).wav")
        try writeWav(samples, rate: rate, to: url)
        try s.refText.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        print("ref-\(s.lang.rawValue): \(f(stats?.audioSeconds ?? 0)) s Audio, RTF \(f(stats?.realTimeFactor ?? 0)), mlxPeak \(f(stats?.mlxPeakGB ?? 0)) GB, nan=\(c.nan) peak=\(f(Double(c.peak)))")
    }
    print("Footprint-Spitze: \(f(footprintGB().peak)) GB")
}

func runBench(bits: ModelBits, out: URL, interval: Double, langs: Set<String>) async throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let b = bits.rawValue
    let engine = MLXQwenEngine(bits: bits)
    await engine.setStreamingInterval(interval)
    print("== Base \(b)-bit, Streaming-Intervall \(interval) s ==")
    print("Footprint vor Laden: \(f(footprintGB().now)) GB")
    let t0 = Date()
    try await engine.load(.base)
    let loadTime = Date().timeIntervalSince(t0)
    let rate = await engine.sampleRate
    print("Ladezeit: \(f(loadTime)) s, Modellrate \(rate) Hz, Footprint nach Laden \(f(footprintGB().now)) GB")

    for s in sets where langs.contains(s.lang.rawValue) {
        let refURL = out.appendingPathComponent("refs/ref-\(s.lang.rawValue).wav")
        let voice = Voice(id: "ref-\(s.lang.rawValue)", name: "Ref", language: s.lang, kind: .designed,
                          referenceAudio: refURL, referenceText: s.refText)
        let tp = Date()
        let handle = try await engine.prepare(voice)
        let prepTime = Date().timeIntervalSince(tp)
        print("[\(s.lang.rawValue)] prepare (Klon-Prompt): \(f(prepTime)) s")

        var totalAudio = 0.0, totalWall = 0.0
        for (i, text) in s.chunks.enumerated() {
            let seed = SeedDerivation.seed(projectID: spikeProject, chunkIndex: i, attempt: 0)
            var all = [Float]()
            for try await part in await engine.speak(text, voice: handle, language: s.lang, seed: seed) { all += part }
            let st = await engine.lastStats!
            let c = check(all, rate: rate)
            totalAudio += st.audioSeconds; totalWall += st.wallSeconds
            let name = "\(s.lang.rawValue)-\(b)bit-\(i + 1).wav"
            try writeWav(all, rate: rate, to: out.appendingPathComponent(name))
            print("[\(s.lang.rawValue)] \(i + 1): \(text.count) Zeichen, \(f(st.audioSeconds)) s Audio, \(f(st.wallSeconds)) s Rechenzeit, RTF \(f(st.realTimeFactor)), erstes Audio nach \(f(st.timeToFirstAudio)) s, mlxPeak \(f(st.mlxPeakGB)) GB, nan=\(c.nan) peak=\(f(Double(c.peak))) rms=\(f(Double(c.rms), 3)) Stille-Ende=\(f(c.trailingSilence)) s -> \(name)")
        }
        print("[\(s.lang.rawValue)] gesamt: RTF \(f(totalWall / totalAudio)) (\(f(totalAudio)) s Audio)")

        // Determinismus: gleicher Seed zweimal
        if s.lang == .de {
            var a = [Float](), b2 = [Float]()
            let seed = SeedDerivation.seed(projectID: spikeProject, chunkIndex: 99, attempt: 0)
            let short = "Das ist ein kurzer Test, um zu prüfen, ob derselbe Startwert dieselbe Aufnahme ergibt."
            for try await p in await engine.speak(short, voice: handle, language: s.lang, seed: seed) { a += p }
            for try await p in await engine.speak(short, voice: handle, language: s.lang, seed: seed) { b2 += p }
            let same = a.count == b2.count && a == b2
            var maxDiff: Float = 0
            if a.count == b2.count { for i in 0..<a.count { maxDiff = max(maxDiff, abs(a[i] - b2[i])) } }
            print("[de] Seed-Determinismus: Länge \(a.count)/\(b2.count), identisch=\(same), maxDiff=\(maxDiff)")
        }
        await engine.release(handle)
    }
    let fp = footprintGB()
    print("Footprint jetzt \(f(fp.now)) GB, Spitze (phys_footprint) \(f(fp.peak)) GB")
    await engine.unload()
    print("Footprint nach Entladen: \(f(footprintGB().now)) GB")
}

let cmd = CommandLine.arguments.dropFirst().first ?? ""
let outDir = URL(fileURLWithPath: arg("--out") ?? "spike-output/S1")
do {
    switch cmd {
    case "refs":
        try await runRefs(out: outDir.appendingPathComponent("refs"))
    case "bench":
        let bits = ModelBits(rawValue: Int(arg("--bits") ?? "4") ?? 4) ?? .four
        let langs = Set((arg("--langs") ?? "de,pt").split(separator: ",").map(String.init))
        try await runBench(bits: bits, out: outDir, interval: Double(arg("--interval") ?? "0.32") ?? 0.32, langs: langs)
    default:
        print("Aufruf: spike-s1 refs|bench ...")
    }
} catch {
    print("FEHLER: \(error)")
    exit(1)
}
