import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    property alias cfg_commandPath: commandPathField.text
    property string cfg_commandPathDefault
    property alias cfg_provider: providerField.text
    property string cfg_providerDefault
    property alias cfg_source: sourceField.text
    property string cfg_sourceDefault
    property alias cfg_refreshInterval: refreshIntervalSpin.value
    property int cfg_refreshIntervalDefault
    property alias cfg_includeStatus: includeStatusCheck.checked
    property bool cfg_includeStatusDefault
    property alias cfg_usageBarsShowUsed: usageBarsShowUsedCheck.checked
    property bool cfg_usageBarsShowUsedDefault
    property alias cfg_showProviderChangelogs: showProviderChangelogsCheck.checked
    property bool cfg_showProviderChangelogsDefault
    property alias cfg_showProviderInPanel: showProviderCheck.checked
    property bool cfg_showProviderInPanelDefault
    property alias cfg_showPercentInPanel: showPercentCheck.checked
    property bool cfg_showPercentInPanelDefault
    property alias cfg_showMultiProviderInPanel: showMultiProviderCheck.checked
    property bool cfg_showMultiProviderInPanelDefault
    property alias cfg_showCreditsInPanel: showCreditsCheck.checked
    property bool cfg_showCreditsInPanelDefault

    Kirigami.FormLayout {
        Controls.TextField {
            id: commandPathField
            Kirigami.FormData.label: i18n("Command path:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            placeholderText: "codexbar"
        }

        Controls.TextField {
            id: providerField
            Kirigami.FormData.label: i18n("Provider:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            placeholderText: i18n("Provider id (blank = all enabled)")
        }

        Controls.TextField {
            id: sourceField
            Kirigami.FormData.label: i18n("Source:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            placeholderText: i18n("Provider default (blank)")
        }

        Controls.SpinBox {
            id: refreshIntervalSpin
            Kirigami.FormData.label: i18n("Refresh:")
            from: 10
            to: 3600
            stepSize: 10
            editable: true
            textFromValue: function(value, locale) {
                return i18n("%1 s", value)
            }
            valueFromText: function(text, locale) {
                var match = text.match(/\d+/)
                return match ? parseInt(match[0], 10) : 300
            }
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }

        Controls.CheckBox {
            id: includeStatusCheck
            text: i18n("Fetch provider status")
        }

        Controls.CheckBox {
            id: usageBarsShowUsedCheck
            text: i18n("Show usage as percent used")
        }

        Controls.CheckBox {
            id: showProviderChangelogsCheck
            text: i18n("Show provider changelog links")
        }

        Controls.CheckBox {
            id: showProviderCheck
            text: i18n("Show provider in panel")
        }

        Controls.CheckBox {
            id: showPercentCheck
            text: i18n("Show percent in panel")
        }

        Controls.CheckBox {
            id: showMultiProviderCheck
            text: i18n("Show multi-provider details in panel")
        }

        Controls.CheckBox {
            id: showCreditsCheck
            text: i18n("Show credits in panel")
        }
    }
}
