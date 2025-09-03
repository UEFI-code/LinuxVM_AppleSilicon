import Virtualization
import AppKit

@main
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {

    @IBOutlet var window: NSWindow!

    @IBOutlet weak var virtualMachineView: VZVirtualMachineView!

    private var virtualMachine: VZVirtualMachine!

    private var installerISOPath: URL?

    private var needsInstall = true

    private var vmDirectoryURL: URL!
    private var cpuCount: Int = 2
    private var memorySize: UInt64 = 4 * 1024 * 1024 * 1024
    private var newDiskSizeGB: Int = 10
    private let diskImageName = "Disk.img"
    private let efiStoreName = "NVRAM"
    private let machineIDName = "MachineIdentifier"

    override init() {
        super.init()
    }

    private func diskImagePath() -> String { vmDirectoryURL.appendingPathComponent(diskImageName).path }
    private func efiVariableStorePath() -> String { vmDirectoryURL.appendingPathComponent(efiStoreName).path }
    private func machineIdentifierPath() -> String { vmDirectoryURL.appendingPathComponent(machineIDName).path }

    private func createMainDiskImage(sizeGB: Int) {
        let path = diskImagePath()
        if FileManager.default.fileExists(atPath: path) { return }
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        let h = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! h.truncate(atOffset: UInt64(sizeGB) * 1024 * 1024 * 1024)
    }

    private func createBlockDeviceConfiguration() -> VZVirtioBlockDeviceConfiguration {
    let mainDiskAttachment = try! VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskImagePath()), readOnly: false)

        let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
        return mainDisk
    }

    private func createAndSaveMachineIdentifier() -> VZGenericMachineIdentifier {
        let machineIdentifier = VZGenericMachineIdentifier()
        try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: machineIdentifierPath()))
        return machineIdentifier
    }

    private func retrieveMachineIdentifier() -> VZGenericMachineIdentifier {
    let machineIdentifierData = try! Data(contentsOf: URL(fileURLWithPath: machineIdentifierPath()))

        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            fatalError("Failed to create the machine identifier.")
        }

        return machineIdentifier
    }

    private func createEFIVariableStore() -> VZEFIVariableStore {
    let efiVariableStore = try! VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVariableStorePath()))

        return efiVariableStore
    }

    private func retrieveEFIVariableStore() -> VZEFIVariableStore {
        if !FileManager.default.fileExists(atPath: efiVariableStorePath()) {
            fatalError("EFI variable store does not exist.")
        }
        return VZEFIVariableStore(url: URL(fileURLWithPath: efiVariableStorePath()))
    }

    private func createUSBMassStorageDeviceConfiguration() -> VZUSBMassStorageDeviceConfiguration {
    let intallerDiskAttachment = try! VZDiskImageStorageDeviceAttachment(url: installerISOPath!, readOnly: true)

        return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
    }

    private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        return networkDevice
    }

    private func createGraphicsDeviceConfiguration() -> VZVirtioGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
        ]

        return graphicsDevice
    }

    private func createInputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let inputAudioDevice = VZVirtioSoundDeviceConfiguration()

        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()

        inputAudioDevice.streams = [inputStream]
        return inputAudioDevice
    }

    private func createOutputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let outputAudioDevice = VZVirtioSoundDeviceConfiguration()

        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()

        outputAudioDevice.streams = [outputStream]
        return outputAudioDevice
    }

    private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()

        let spiceAgentPort = VZVirtioConsolePortConfiguration()
        spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
        consoleDevice.ports[0] = spiceAgentPort

        return consoleDevice
    }

    // MARK: Create the virtual machine configuration and instantiate the virtual machine.

    func createVirtualMachine() {
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        virtualMachineConfiguration.cpuCount = cpuCount
        virtualMachineConfiguration.memorySize = memorySize

        let platform = VZGenericPlatformConfiguration()
        let bootloader = VZEFIBootLoader()
        let disksArray = NSMutableArray()

        if needsInstall {
            platform.machineIdentifier = createAndSaveMachineIdentifier()
            bootloader.variableStore = createEFIVariableStore()
            disksArray.add(createUSBMassStorageDeviceConfiguration())
        } else {
            platform.machineIdentifier = retrieveMachineIdentifier()
            bootloader.variableStore = retrieveEFIVariableStore()
        }

        virtualMachineConfiguration.platform = platform
        virtualMachineConfiguration.bootLoader = bootloader

        disksArray.add(createBlockDeviceConfiguration())
        guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
            fatalError("Invalid disksArray.")
        }
        virtualMachineConfiguration.storageDevices = disks

        virtualMachineConfiguration.networkDevices = [createNetworkDeviceConfiguration()]
        virtualMachineConfiguration.graphicsDevices = [createGraphicsDeviceConfiguration()]
        virtualMachineConfiguration.audioDevices = [createInputAudioDeviceConfiguration(), createOutputAudioDeviceConfiguration()]

        virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        virtualMachineConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        virtualMachineConfiguration.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]

        try! virtualMachineConfiguration.validate()
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
    }

    // MARK: Start the virtual machine.

    func configureAndStartVirtualMachine() {
        DispatchQueue.main.async {
            self.createVirtualMachine()
            self.virtualMachineView.virtualMachine = self.virtualMachine

            if #available(macOS 14.0, *) { self.virtualMachineView.automaticallyReconfiguresDisplay = true }

            self.virtualMachine.delegate = self
            self.virtualMachine.start(completionHandler: { (result) in
                switch result {
                case let .failure(error):
                    fatalError("Virtual machine failed to start with error: \(error)")

                default:
                    print("Virtual machine successfully started.")
                }
            })
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        selectVMDirectory()
        needsInstall = !FileManager.default.fileExists(atPath: diskImagePath())
        promptForConfig()
        if needsInstall {
            createMainDiskImage(sizeGB: newDiskSizeGB)
            selectISO()
        }
        configureAndStartVirtualMachine()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: VZVirtualMachineDelegate methods.

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("Virtual machine did stop with error: \(error.localizedDescription)")
        exit(-1)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("Guest did stop virtual machine.")
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        print("Netowrk attachment was disconnected with error: \(error.localizedDescription)")
    }

    private func selectVMDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose VM storage path"
        var done = false
        panel.begin { r in
            if r != .OK { fatalError("You didn't choose a path") }
            self.vmDirectoryURL = panel.url!
            done = true
        }
        // wait for panel finish
        while !done {
            RunLoop.current.run(mode: .default, before: Date.distantFuture)
        }
    }

    private func promptForConfig() {
        let alert = NSAlert()
        alert.messageText = "Configure Virtual Machine"
        alert.informativeText = "Enter numeric values."

        // Create numeric text fields with formatter to avoid non‑numeric input.
        let intFormatter = NumberFormatter()
        intFormatter.allowsFloats = false
        intFormatter.minimum = 1

        func makeField(value: Int) -> NSTextField {
            let f = NSTextField(string: "\(value)")
            f.formatter = intFormatter
            f.alignment = .right
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return f
        }

        let cpuField = makeField(value: cpuCount)
        let memField = makeField(value: Int(memorySize / (1024*1024*1024)))
        var diskField: NSTextField? = needsInstall ? makeField(value: newDiskSizeGB) : nil

        // Use NSGridView for stable layout inside NSAlert accessory view.
        var rows: [[NSView]] = [
            [NSTextField(labelWithString: "CPU"), cpuField],
            [NSTextField(labelWithString: "RAM (GB)"), memField]
        ]
        if let d = diskField { rows.append([NSTextField(labelWithString: "Disk (GB)"), d]) }

        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.setContentHuggingPriority(.required, for: .horizontal)

        // Wrap in container so we can constrain width if needed.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])

        alert.accessoryView = container
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        // Make sure layout is performed so alert sizes correctly.
        container.layoutSubtreeIfNeeded()

        if let window = alert.window as NSWindow? { window.initialFirstResponder = cpuField }

        let response = alert.runModal()
        if response != .alertFirstButtonReturn { fatalError("Cancelled") }
        if let v = Int(cpuField.stringValue), v > 0 { cpuCount = v }
        if let v = Int(memField.stringValue), v > 0 { memorySize = UInt64(v) * 1024 * 1024 * 1024 }
        if needsInstall, let f = diskField, let v = Int(f.stringValue), v > 0 { newDiskSizeGB = v }
    }

    private func selectISO() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose ISO"
        openPanel.message = "Choose installation ISO file"
        var done = false
        openPanel.begin { r in
            if r != .OK { fatalError("No ISO selected") }
            self.installerISOPath = openPanel.url!
            done = true
        }
        // wait for user to select ISO
        while !done {
            RunLoop.current.run(mode: .default, before: Date.distantFuture)
        }
    }
}