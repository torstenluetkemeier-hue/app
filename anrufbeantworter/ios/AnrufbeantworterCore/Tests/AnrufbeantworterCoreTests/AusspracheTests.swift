import XCTest
@testable import AnrufbeantworterCore

final class AusspracheTests: XCTestCase {
    // MARK: Wörterbuch anwenden

    func testLautschriftWirdGanzwortigEingesetzt() {
        let lex = [AusspracheEintrag(schreibweise: "Nguyen", lautschrift: "Nuien", pruefung: .korrigiert)]
        let teile = Aussprache.zerlege("Frau Nguyen ruft an. Nguyenstraße bleibt.", lexikon: lex)
        XCTAssertEqual(Aussprache.gesprochenerText(teile), "Frau Nuien ruft an. Nguyenstraße bleibt.")
    }

    func testGrossKleinschreibungEgal() {
        let lex = [AusspracheEintrag(schreibweise: "tomedo", lautschrift: "To-mee-do", pruefung: .korrigiert)]
        XCTAssertEqual(Aussprache.gesprochenerText(Aussprache.zerlege("Ihr Team für TOMEDO.", lexikon: lex)), "Ihr Team für To-mee-do.")
    }

    func testLaengererEintragHatVorrang() {
        let lex = [
            AusspracheEintrag(schreibweise: "Szczepański", lautschrift: "Schtschepanski", pruefung: .korrigiert),
            AusspracheEintrag(schreibweise: "Krzysztof Szczepański", lautschrift: "Kschischtof Schtschepanski", pruefung: .korrigiert),
        ]
        let teile = Aussprache.zerlege("Hier ist Krzysztof Szczepański.", lexikon: lex)
        XCTAssertEqual(teile.count, 3)
        XCTAssertEqual(Aussprache.gesprochenerText(teile), "Hier ist Kschischtof Schtschepanski.")
    }

    func testNurGeprueftOhneKorrekturAendertNichts() {
        let lex = [AusspracheEintrag(schreibweise: "Meyer", pruefung: .ok)]
        XCTAssertEqual(Aussprache.zerlege("Max Meyer", lexikon: lex), [.text("Max Meyer")])
    }

    func testIPAHatVorrangUndSSML() {
        let lex = [AusspracheEintrag(schreibweise: "Çelik", lautschrift: "Tschelik", ipa: "tʃeˈlik", pruefung: .korrigiert)]
        let teile = Aussprache.zerlege("Herr Çelik & Co", lexikon: lex)
        XCTAssertEqual(teile[1], .korrigiert(original: "Çelik", lautschrift: "Tschelik", ipa: "tʃeˈlik"))
        XCTAssertEqual(Aussprache.ssml(teile), "<speak>Herr <phoneme alphabet=\"ipa\" ph=\"tʃeˈlik\">Çelik</phoneme> &amp; Co</speak>")
        let nurLaut = Aussprache.zerlege("Çelik", lexikon: [AusspracheEintrag(schreibweise: "Çelik", lautschrift: "Tschelik", pruefung: .korrigiert)])
        XCTAssertEqual(Aussprache.ssml(nurLaut), "<speak><sub alias=\"Tschelik\">Çelik</sub></speak>")
    }

    func testSpeichernErsetztGleicheSchreibweise() {
        var lex: [AusspracheEintrag] = []
        Aussprache.speichere(AusspracheEintrag(schreibweise: "Nguyen", pruefung: .ok), in: &lex)
        Aussprache.speichere(AusspracheEintrag(schreibweise: "nguyen", lautschrift: "Nuien", pruefung: .korrigiert), in: &lex)
        XCTAssertEqual(lex.count, 1)
        XCTAssertEqual(lex[0].lautschrift, "Nuien")
    }

    // MARK: Risiko-Einschätzung

    func testDeutscheNamenSindUnauffaellig() {
        for n in ["Max Meyer", "Thomas Müller", "Christian Wagner", "Joachim Keller", "Sebastian Richter", "Schmidt-Öztürk", "Anna Kowalski", "zollsoft"] {
            XCTAssertEqual(AusspracheRisiko.bewerte(n).stufe, .gering, n)
        }
    }

    func testSchwierigeNamenWerdenErkannt() {
        let hoch = ["Krzysztof Szczepański", "Gülşen Yılmaz", "Nguyen Thi Huong", "Jacques Dubois", "Siobhan O'Connor", "Xiao Zhang", "Wojciechowski", "Joaquín García"]
        for n in hoch { XCTAssertEqual(AusspracheRisiko.bewerte(n).stufe, .hoch, n) }
        XCTAssertEqual(AusspracheRisiko.bewerte("MVZ").stufe, .mittel)
        XCTAssertTrue(AusspracheRisiko.bewerte("Gülşen Yılmaz").herkunft.contains(.tuerkisch))
    }

    // MARK: Vorschläge

    func testVorschlaegeFuerBekannteUndUnbekannteNamen() {
        XCTAssertEqual(AusspracheRisiko.vorschlaege("Nguyen").first?.lautschrift, "Nuien")
        XCTAssertEqual(AusspracheRisiko.vorschlaege("Ahmet Çelik").first?.lautschrift, "Ahmet Tschelik")
        XCTAssertTrue(AusspracheRisiko.vorschlaege("MVZ").contains { $0.lautschrift == "M V Z" })
        XCTAssertTrue(AusspracheRisiko.vorschlaege("Max Meyer").isEmpty)
    }

    func testUmschriftErsetztNichtDoppelt() {
        XCTAssertEqual(AusspracheRisiko.umschreiben("Gülşen", .tuerkisch), "Gülschen")
        XCTAssertEqual(AusspracheRisiko.umschreiben("Krzysztof", .polnisch), "Kschischtof")
        XCTAssertEqual(AusspracheRisiko.umschreiben("Zhang", .chinesisch), "Dschang")
        XCTAssertEqual(AusspracheRisiko.umschreiben("Moreau", .franzoesisch), "Moro")
        XCTAssertEqual(AusspracheRisiko.umschreiben("Schmidt-Çelik", .tuerkisch), "Schmidt-Tschelik")
    }

    // MARK: Prüfliste

    func testKandidatenUndStatus() {
        var k = AppKonfiguration.beispiel
        k.vertretungen.append(Vertretung(name: "Gülşen Yılmaz", telefon: "0171 1234567"))
        k.testnamen = ["Krzysztof Szczepański"]
        var kandidaten = NamensPruefung.kandidaten(k, stimmeID: "anna")
        XCTAssertEqual(kandidaten.map(\.name), ["Max Meyer", "Thomas Müller", "Gülşen Yılmaz", "zollsoft", "tomedo", "Krzysztof Szczepański"])
        XCTAssertEqual(NamensPruefung.offeneHinweise(k, stimmeID: "anna").map(\.name), ["Gülşen Yılmaz"], "Testnamen und unauffällige Namen erzeugen keinen Hinweis")

        Aussprache.speichere(AusspracheEintrag(schreibweise: "Gülşen Yılmaz", lautschrift: "Gülschen Jilmas", pruefung: .korrigiert, gepruefteStimme: "anna"), in: &k.lexikon)
        kandidaten = NamensPruefung.kandidaten(k, stimmeID: "anna")
        XCTAssertEqual(kandidaten.first { $0.name == "Gülşen Yılmaz" }?.status, .korrigiert)
        XCTAssertTrue(NamensPruefung.offeneHinweise(k, stimmeID: "anna").isEmpty)

        // Nach Stimmwechsel: erneut anhören empfohlen
        XCTAssertEqual(NamensPruefung.kandidaten(k, stimmeID: "markus").first { $0.name == "Gülşen Yılmaz" }?.status, .stimmeGeaendert)
    }

    func testNeueNamenWerdenErkannt() {
        let alt = AppKonfiguration.beispiel
        var neu = alt
        neu.vertretungen.append(Vertretung(name: "Siobhan O'Connor", telefon: "1"))
        XCTAssertEqual(NamensPruefung.neueNamen(alt: alt, neu: neu), ["Siobhan O'Connor"])
    }

    func testAlleBeispielnamenHabenVorschlaegeOderSindUnkritisch() {
        for n in NamensPruefung.beispielNamen {
            let b = AusspracheRisiko.bewerte(n)
            if b.stufe == .hoch { XCTAssertFalse(AusspracheRisiko.vorschlaege(n).isEmpty, n) }
        }
    }

    func testRufnummerZumSprechen() {
        XCTAssertEqual(Rufnummer.zumSprechen("+49 3641 000 200"), "0 3 6 4 1, 0 0 0, 2 0 0")
        XCTAssertEqual(Rufnummer.zumSprechen("01711234567"), "0 1 7, 1 1 2, 3 4 5, 6 7")
        XCTAssertEqual(Rufnummer.zumSprechen("0171/123 45-67"), "0 1 7 1, 1 2 3, 4 5, 6 7")
    }
}
