import Foundation

/// Feld-Katalog der Site (GET /rest/api/3/field), einmal pro Site und
/// Session geladen. Custom-Field-IDs sind instanzspezifisch — Team, Sprint
/// und Testplan werden deshalb über Typ/Name gefunden statt hartkodiert.
@MainActor
final class JiraFieldCatalog {
    static let shared = JiraFieldCatalog()

    private var fields: [FieldDTO]?
    private var fieldsBaseURL: URL?
    private var loading: Task<[FieldDTO], Never>?

    private init() {}

    /// Alle Felder; parallele Aufrufe teilen sich einen Request. Ein Fehler
    /// wird nicht gecacht (nächster Aufruf versucht es erneut).
    func allFields(client: JiraClient) async -> [FieldDTO] {
        if let fields, fieldsBaseURL == client.baseURL { return fields }
        if let loading { return await loading.value }
        let task = Task { (try? await client.allFields()) ?? [] }
        loading = task
        let result = await task.value
        loading = nil
        if !result.isEmpty {
            fields = result
            fieldsBaseURL = client.baseURL
        }
        return result
    }

    /// Mehrzeiliges Textfeld für Testanweisungen („Testplan" bzw.
    /// „Testanweisung") — nil, wenn die Site keins hat.
    func testPlanField(client: JiraClient) async -> FieldDTO? {
        let names: Set<String> = ["testplan", "test plan", "testanweisung", "testanweisungen"]
        return await allFields(client: client).first { field in
            field.schema?.custom == "com.atlassian.jira.plugin.system.customfieldtypes:textarea"
                && names.contains(field.name?.lowercased() ?? "")
        }
    }
}
