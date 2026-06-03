import Foundation
import SSHAutoTunnelCore

struct AppConfigurationArtifactService {
    func export(configuration: AppConfiguration, exportedAt: Date = Date()) -> ConfigurationExport {
        ConfigurationExportService.makeExport(from: configuration, exportedAt: exportedAt)
    }

    func validationReport(
        for export: ConfigurationExport,
        preservingLocalValuesFrom configuration: AppConfiguration
    ) -> ConfigurationValidationReport {
        ConfigurationExportService.validationReport(
            for: export,
            preservingLocalValuesFrom: configuration
        )
    }

    func importConfiguration(
        from export: ConfigurationExport,
        preservingLocalValuesFrom configuration: AppConfiguration
    ) throws -> AppConfiguration {
        try ConfigurationExportService.importConfiguration(
            from: export,
            preservingLocalValuesFrom: configuration
        )
    }

    func supportBundle(
        configuration: AppConfiguration,
        diagnostics: DiagnosticsSnapshot,
        generatedAt: Date
    ) -> SupportBundle {
        ConfigurationExportService.makeSupportBundle(
            configuration: configuration,
            diagnostics: diagnostics,
            generatedAt: generatedAt
        )
    }
}
