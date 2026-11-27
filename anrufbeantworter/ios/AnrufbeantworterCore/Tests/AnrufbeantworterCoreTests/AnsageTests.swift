import XCTest
@testable import AnrufbeantworterCore

/// Hilfsfunktion: lokale Berliner Zeit "2026-11-27 10:00"
func berlin(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = Zeit.zeitzone
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

final class AnsageTests: XCTestCase {
    let jetzt = berlin("2026-11-27 10:00") // Freitag

    func testStandardansageNenntNameFirmaUndProdukt() {
        let a = AnsageEngine.erstelle(.beispiel, jetzt: jetzt)
        XCTAssertEqual(a.status.quelle, .standard)
        XCTAssertTrue(a.text.hasPrefix("Guten Tag! Sie sind verbunden mit dem Anschluss von Max Meyer, Kundenberater bei zollsoft, Ihrem Team für tomedo."))
        XCTAssertTrue(a.text.contains("Leider bin ich gerade nicht erreichbar."))
        XCTAssertTrue(a.text.hasSuffix("Vielen Dank für Ihren Anruf!"))
        XCTAssertFalse(a.text.contains("Thomas Müller"), "Im Standard wird keine Vertretung genannt")
    }

    func testOnlinePraesentationMitUhrzeit() {
        var k = AppKonfiguration.beispiel
        k.status = Status(modus: .termin, terminArt: .onlinePraesentation, bis: berlin("2026-11-27 11:30"))
        let a = AnsageEngine.erstelle(k, jetzt: jetzt)
        XCTAssertTrue(a.text.contains("Ich bin gerade in einer Online-Präsentation, voraussichtlich bis 11 Uhr 30, und daher nicht erreichbar."), a.text)
    }

    func testAbgelaufenerStatusFaelltAufStandardZurueck() {
        var k = AppKonfiguration.beispiel
        k.status = Status(modus: .termin, terminArt: .schulung, bis: berlin("2026-11-27 09:00"))
        XCTAssertEqual(AnsageEngine.aktiverStatus(k, jetzt: jetzt).status.modus, .standard)
    }

    func testUrlaubNenntVertretungMitGesprochenerNummer() {
        var k = AppKonfiguration.beispiel
        k.status = Status(modus: .urlaub, bis: berlin("2026-12-04 00:00"))
        let a = AnsageEngine.erstelle(k, jetzt: jetzt)
        XCTAssertTrue(a.text.contains("Ich bin im Urlaub, bis einschließlich Freitag, 4. Dezember."), a.text)
        XCTAssertTrue(a.text.contains("In dringenden Fällen erreichen Sie Thomas Müller unter 0 3 6 4 1, 0 0 0, 2 0 0."), a.text)
        // ganztägig: am letzten Tag abends noch aktiv
        XCTAssertEqual(AnsageEngine.aktiverStatus(k, jetzt: berlin("2026-12-04 22:00")).status.modus, .urlaub)
        XCTAssertEqual(AnsageEngine.aktiverStatus(k, jetzt: berlin("2026-12-05 08:00")).status.modus, .standard)
    }

    func testVertretungAbwaehlbar() {
        var k = AppKonfiguration.beispiel
        k.status = Status(modus: .urlaub, vertretung: .keine)
        XCTAssertFalse(AnsageEngine.erstelle(k, jetzt: jetzt).text.contains("Thomas"))
    }

    func testKalenderTerminGewinntGegenDienstreise() {
        var k = AppKonfiguration.beispiel
        k.kalender = [
            KalenderEintrag(von: berlin("2026-11-25 00:00"), status: Status(modus: .abwesend, abwesendArt: .messe, bis: berlin("2026-11-28 00:00"))),
            KalenderEintrag(von: berlin("2026-11-27 09:00"), status: Status(modus: .termin, terminArt: .praesentationVorOrt, bis: berlin("2026-11-27 12:00"))),
        ]
        XCTAssertEqual(AnsageEngine.aktiverStatus(k, jetzt: jetzt).status.modus, .termin)
        XCTAssertEqual(AnsageEngine.aktiverStatus(k, jetzt: berlin("2026-11-27 13:00")).status.modus, .abwesend)
        XCTAssertTrue(AnsageEngine.erstelle(k, jetzt: berlin("2026-11-27 13:00")).text.contains("Ich bin auf einer Messe, bis einschließlich Samstag, 28. November, und nur eingeschränkt erreichbar."))
    }

    func testFreitextBeiSonstiges() {
        var k = AppKonfiguration.beispiel
        k.status = Status(modus: .termin, terminArt: .sonstiges, freitext: "in einem Workshop")
        XCTAssertTrue(AnsageEngine.erstelle(k, jetzt: jetzt).text.contains("Ich bin gerade in einem Workshop und daher nicht erreichbar."))
    }

    func testVorlageMitBedingtenAbschnitten() {
        XCTAssertEqual(Vorlage.render("A{{#x}}, {{x}}{{/x}}.{{^y}} ohne y{{/y}}", ["x": "1"]), "A, 1. ohne y")
        XCTAssertEqual(Vorlage.render("A{{#x}}, {{x}}{{/x}}.", [:]), "A.")
    }

    func testAbweichungVomFirmenstandard() {
        var t = AnsageTexte.firmenStandard
        XCTAssertEqual(t.abweichungenVomStandard, 0)
        t.abschluss = "Tschüss!"
        XCTAssertEqual(t.abweichungenVomStandard, 1)
    }

    func testKonfigurationIstCodable() throws {
        var k = AppKonfiguration.beispiel
        k.status = Status(modus: .termin, vertretung: .person(k.vertretungen[0].id))
        k.lexikon = [AusspracheEintrag(schreibweise: "Meyer", pruefung: .ok)]
        let data = try JSONEncoder().encode(k)
        XCTAssertEqual(try JSONDecoder().decode(AppKonfiguration.self, from: data), k)
    }
}
