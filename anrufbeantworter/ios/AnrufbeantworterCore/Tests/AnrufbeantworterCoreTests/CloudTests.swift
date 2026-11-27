import XCTest
@testable import AnrufbeantworterCore

final class CloudTests: XCTestCase {
    func testRufumleitungsCodes() {
        let codes = Rufumleitung.einrichten(nummer: "030 111 222", sekunden: 22)
        XCTAssertEqual(codes.map(\.code), ["**61*+4930111222*11*20#", "**67*+4930111222#", "**62*+4930111222#"])
        XCTAssertEqual(Rufumleitung.zielnummer("+49 (0) 30 111222"), "+4930111222")
        XCTAssertEqual(Rufumleitung.zielnummer("0049 30 111222"), "+4930111222")
        XCTAssertEqual(Rufumleitung.klingeldauer(2), 5)
        XCTAssertEqual(Rufumleitung.klingeldauer(99), 30)
    }

    func testServerVorlage() {
        XCTAssertEqual(CloudPayload.serverVorlage(AnsageTexte.firmenStandard.intro, intro: true),
                       "{{begruessung}}! Sie sind verbunden mit dem Anschluss von {{ich.name}}{{#ich.funktion}}, {{ich.funktion}}{{/ich.funktion}} bei {{firma.name}}, Ihrem Team für {{firma.produkt}}.")
        XCTAssertEqual(CloudPayload.serverVorlage(AnsageTexte.firmenStandard.vertretung),
                       "In dringenden Fällen erreichen Sie {{vertretung.name}} unter {{vertretung.telefonAnsage}}.")
    }

    func testPayload() throws {
        var k = AppKonfiguration.beispiel
        k.status = Status(modus: .termin, terminArt: .praesentationVorOrt, bis: berlin("2026-11-27 15:30"), vertretung: .keine)
        k.kalender = [KalenderEintrag(titel: "Urlaub", von: berlin("2026-12-21 00:00"),
                                      status: Status(modus: .urlaub, bis: berlin("2027-01-04 00:00"), vertretung: .person(k.vertretungen[0].id)))]
        k.lexikon = [
            AusspracheEintrag(schreibweise: "Meyer", pruefung: .ok),
            AusspracheEintrag(schreibweise: "Nguyen", lautschrift: "Nuien", pruefung: .korrigiert),
        ]
        k.cloud = CloudEinstellung(aktiv: true, serverURL: "https://ab.example.de", mobilnummer: "0171 9998877")
        let p = CloudPayload(k)
        XCTAssertEqual(p.status, .init(modus: "termin", art: "praesentation-vor-ort", freitext: "", bis: "2026-11-27T15:30", ganztags: false, vertretungId: ""))
        XCTAssertEqual(p.kalender.first?.von, "2026-12-21")
        XCTAssertEqual(p.kalender.first?.bis, "2027-01-04")
        XCTAssertEqual(p.kalender.first?.vertretungId, k.vertretungen[0].id.uuidString)
        XCTAssertEqual(p.lexikon.map(\.schreibweise), ["Nguyen"], "nur Einträge mit Korrektur")
        XCTAssertEqual(p.vertretungNennenIn, ["abwesend", "krank", "urlaub"])
        XCTAssertEqual(p.cloud.mobilnummer, "0171 9998877")

        // "automatisch" wird weggelassen (Server nimmt dann die Standard-Vertretung)
        k.status?.vertretung = .automatisch
        let json = String(decoding: try CloudPayload(k).json(), as: UTF8.self)
        XCTAssertFalse(json.contains("\"vertretungId\":\"\",\"modus\":\"termin\""))
        XCTAssertTrue(json.contains("\"status\":{\"art\":\"praesentation-vor-ort\",\"bis\":\"2026-11-27T15:30\",\"freitext\":\"\",\"ganztags\":false,\"modus\":\"termin\"}"), json)
    }

    func testKalenderOhneEnde() {
        var k = AppKonfiguration.beispiel
        k.kalender = [KalenderEintrag(von: berlin("2026-12-02 09:00"), status: Status(modus: .termin, terminArt: .schulung))]
        let e = CloudPayload(k).kalender[0]
        XCTAssertEqual(e.von, "2026-12-02T09:00")
        XCTAssertEqual(e.bis, "2026-12-02T23:59")
        XCTAssertEqual(e.art, "schulung")
    }

    func testAlteKonfigurationOhneCloudLaesstSichLesen() throws {
        var k = AppKonfiguration.beispiel
        k.cloud = nil
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(k)) as! [String: Any]
        dict.removeValue(forKey: "cloud")
        let alt = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertNil(try JSONDecoder().decode(AppKonfiguration.self, from: alt).cloud)
    }

    /// Schreibt eine Beispiel-Übertragung, die der Node-Test (test/cloud.test.js) gegen den Server prüft.
    func testBeispielPayloadFuerServerTest() throws {
        var k = AppKonfiguration.beispiel
        k.vertretungen.append(Vertretung(name: "Gülşen Yılmaz", telefon: "0171 2223344"))
        k.status = Status(modus: .termin, terminArt: .onlinePraesentation, bis: berlin("2099-01-01 15:00"))
        k.lexikon = [AusspracheEintrag(schreibweise: "Gülşen Yılmaz", lautschrift: "Gülschen Jilmas", pruefung: .korrigiert)]
        k.vertretungNennenIn = [.termin, .urlaub]
        k.standardVertretungID = k.vertretungen[1].id
        let data = try CloudPayload(k).json()
        if let ziel = ProcessInfo.processInfo.environment["PAYLOAD_EXPORT"] {
            try data.write(to: URL(fileURLWithPath: ziel))
        }
        XCTAssertGreaterThan(data.count, 500)
    }
}
