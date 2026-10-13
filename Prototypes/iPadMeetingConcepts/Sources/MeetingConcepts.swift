import SwiftUI

enum PrototypeScreen: String { case ready, active, processing, completed, settings, privacy, models, history }

struct PrototypeRoot: View {
    let options: PrototypeOptions
    @State private var screen: PrototypeScreen
    @State private var currentMeetingState: PrototypeScreen
    @State private var selectedSessionID = 1
    @State private var saveAudio = true
    @State private var diarization = true
    @State private var includePlace = false
    @State private var paused = false
    @State private var showEnrollment = false
    @State private var showValidation = false
    @State private var showHistory = false
    @State private var showExport = false
    @State private var showCopy = false
    @StateObject private var replay = MeetingLiveReplayController()
    @State private var processingIndex = 0
    @State private var processingTask: Task<Void, Never>?
    @State private var completedReplayDuration: TimeInterval?
    private var theme: PrototypeTheme { PrototypeTheme(dark: options.dark) }
    private var data: SyntheticFixtures { .shared }

    init(options: PrototypeOptions) {
        self.options = options
        self._screen = State(initialValue: options.screen)
        self._currentMeetingState = State(initialValue: [.ready, .processing, .completed].contains(options.screen) ? options.screen : .active)
        self._saveAudio = State(initialValue: options.saveAudio)
        if let time = options.replayTime {
            let controller = MeetingLiveReplayController()
            controller.renderFrame(at: time)
            self._replay = StateObject(wrappedValue: controller)
        }
    }

    private var displayedSession: SyntheticFixtures.Session {
        screen == .completed ? data.sessions.first(where: { $0.id == selectedSessionID }) ?? data.sessions[0] : data.sessions[0]
    }

    private func showCurrentMeeting() {
        selectedSessionID = data.sessions[0].id
        screen = currentMeetingState
    }

    private func showMeetingSetup() {
        processingTask?.cancel()
        currentMeetingState = .ready
        showCurrentMeeting()
    }

    private func startMeetingPreview() {
        processingTask?.cancel()
        currentMeetingState = .active
        paused = false
        completedReplayDuration = nil
        showCurrentMeeting()
        if options.exportPath == nil { Task { await replay.restart() } }
    }

    private func finishMeetingPreview() {
        currentMeetingState = .processing
        processingIndex = 0
        paused = false
        showCurrentMeeting()
        processingTask?.cancel()
        processingTask = Task { @MainActor in
            await replay.stop()
            completedReplayDuration = replay.currentTime
            for index in 0..<4 {
                guard !Task.isCancelled else { return }
                processingIndex = index
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            }
            currentMeetingState = .completed
            if screen == .processing { showCurrentMeeting() }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            Group {
                if options.layout == "A" {
                    libraryLayout(width: geometry.size.width)
                } else if options.layout == "B" {
                    focusLayout(narrow: narrow)
                } else {
                    dashboardLayout(narrow: narrow)
                }
            }
            .background(theme.color("windowBackground"))
            .foregroundStyle(theme.color("primaryText"))
            .font(theme.font(.body))
            .tint(theme.accent)
        }
        .sheet(isPresented: $showEnrollment) { enrollmentSheet }
        .sheet(isPresented: $showHistory) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    sheetHeader("history") { showHistory = false }
                    historyList(width: geometry.size.width)
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 550, minHeight: 540)
            .background(theme.color("windowBackground"))
        }
        .alert(Copy.text("device_validation"), isPresented: $showValidation) {
            Button(Copy.text("close"), role: .cancel) {}
        } message: { Text(Copy.text("validation_detail")) }
        .alert(Copy.text("export"), isPresented: $showExport) {
            Button(Copy.text("close"), role: .cancel) {}
        } message: { Text(Copy.text("export_detail")) }
        .alert(Copy.text("Copy"), isPresented: $showCopy) {
            Button(Copy.text("close"), role: .cancel) {}
        } message: { Text(Copy.text("copy_preview_detail")) }
        .task {
            if screen == .active && options.exportPath == nil && options.replayTime == nil { await replay.start() }
        }
        .onDisappear {
            processingTask?.cancel()
            Task { await replay.stop() }
        }
    }

    // A: Native library structure. Three columns on a wide iPad, two in portrait,
    // a single content stack plus destinations on iPhone / narrow multitasking.
    private func libraryLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if width >= 700 {
                    sidebar.frame(width: 220)
                    columnDivider
                }
                VStack(spacing: 0) {
                    topBar(compact: width < 700, showBrand: width < 700)
                    divider
                    mainContent(narrow: width < 700, generous: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if width < 700 { divider; bottomNavigation }
        }
    }

    // B: One quiet conversation surface, with almost no surrounding chrome.
    private func focusLayout(narrow: Bool) -> some View {
        VStack(spacing: 0) {
            topBar(compact: narrow, showBrand: true)
            divider
            mainContent(narrow: narrow, generous: true)
                .frame(maxWidth: 850)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            divider
            bottomNavigation
        }
    }

    // C: Field dashboard. Current meeting and daily history coexist as cards.
    private func dashboardLayout(narrow: Bool) -> some View {
        VStack(spacing: 0) {
            topBar(compact: narrow, showBrand: true)
            divider
            if isSettings || screen == .history || screen == .processing {
                mainContent(narrow: narrow, generous: false)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.gap) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 8) {
                                caption("field_work")
                                Text(Copy.text("today_meetings")).font(theme.font(.display))
                            }
                            Spacer()
                            if !narrow { tag("local_only", icon: "ipad") }
                        }
                        if narrow {
                            dashboardCurrent(narrow: true)
                            dashboardHistory
                        } else {
                            HStack(alignment: .top, spacing: theme.gap) {
                                dashboardCurrent(narrow: false).frame(maxWidth: .infinity)
                                dashboardHistory.frame(width: 280)
                            }
                        }
                    }
                    .padding(narrow ? 20 : 32)
                }
            }
            divider
            bottomNavigation
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                theme.brand.logo.resizable().scaledToFit().frame(width: 38, height: 38)
                Text(theme.brand.profile.appName).font(theme.font(.section))
            }.padding(.top, 16)
            VStack(spacing: 8) {
                navRow("meetings", icon: "waveform", selected: isMeeting) { showCurrentMeeting() }
                navRow("history", icon: "clock", selected: screen == .history) { screen = .history }
                navRow("settings", icon: "gearshape", selected: isSettings) { screen = .settings }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label(Copy.text("local_only"), systemImage: "lock.shield")
                    .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                Text(Copy.text("prototype")).font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
            }.padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(theme.color("sidebarBackground"))
    }

    private var isMeeting: Bool { [.ready, .active, .processing, .completed].contains(screen) }
    private var isSettings: Bool { [.settings, .privacy, .models].contains(screen) }
    private var divider: some View { Rectangle().fill(theme.color("separator")).frame(height: 1) }
    private var columnDivider: some View { Rectangle().fill(theme.color("separator")).frame(width: 1) }

    private func topBar(compact: Bool, showBrand: Bool) -> some View {
        HStack(spacing: 12) {
            if screen == .privacy || screen == .models {
                Button { screen = .settings } label: {
                    Label(Copy.text("settings"), systemImage: "chevron.left")
                        .font(theme.font(.body)).frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(theme.accent)
            } else if showBrand {
                theme.brand.logo.resizable().scaledToFit().frame(width: 28, height: 28)
                Text(theme.brand.profile.meetingName).font(theme.font(.section))
            } else {
                Text(Copy.text(screen == .settings ? "settings" : "offline_meeting"))
                    .font(theme.font(.section))
            }
            Spacer(minLength: 8)
            if !compact { Text(Copy.text("prototype")).font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText")) }
            if !isSettings {
                iconButton("plus", label: "new_meeting") { showMeetingSetup() }
                if compact { iconButton("clock", label: "history") { showHistory = true } }
            }
        }
        .padding(.horizontal, compact ? 16 : 24)
        .frame(height: 68)
        .background(theme.color("toolbarBackground"))
    }

    private func historyList(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Copy.text("history")).font(theme.font(.title))
                Spacer()
                iconButton("plus", label: "new_meeting") { showMeetingSetup(); showHistory = false }
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                Text(Copy.text("search_meetings"))
            }
            .font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(theme.color("windowBackground"), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    caption("today").padding(.top, 24).padding(.horizontal, 10)
                    historyRow(data.sessions[0], selected: isMeeting && selectedSessionID == 1, active: currentMeetingState != .completed)
                    caption("previously").padding(.top, 18).padding(.horizontal, 10)
                    ForEach(data.sessions.dropFirst()) { session in
                        historyRow(session, selected: screen == .completed && session.id == selectedSessionID, active: false)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
            Label(Copy.text("demo_data"), systemImage: "sparkles")
                .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                .padding(20)
        }
        .frame(width: width, alignment: .topLeading)
        .background(theme.color("contentBackground"))
    }

    private func historyRow(_ session: SyntheticFixtures.Session, selected: Bool, active: Bool) -> some View {
        Button {
            if active {
                showCurrentMeeting()
            } else {
                selectedSessionID = session.id
                screen = .completed
            }
            showHistory = false
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: active ? "mic" : "text.alignleft").foregroundStyle(theme.accent)
                    Spacer()
                    Text(active ? Copy.text(currentMeetingState == .ready ? "ready" : "in_progress") : session.duration)
                        .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                }
                Text(session.title).font(theme.font(.section)).multilineTextAlignment(.leading)
                Text(session.time).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                if selected && active { Text(Copy.text(saveAudio ? "audio_and_text" : "text_only")).font(theme.font(.caption)).foregroundStyle(theme.accent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(selected ? theme.accent.opacity(options.dark ? 0.15 : 0.08) : theme.color("cardBackground"),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? theme.accent.opacity(0.5) : theme.color("cardBorder").opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func mainContent(narrow: Bool, generous: Bool) -> some View {
        switch screen {
        case .ready: readyScreen(narrow: narrow, generous: generous)
        case .active, .completed: meetingScreen(narrow: narrow, generous: generous)
        case .processing: processingScreen(narrow: narrow)
        case .settings: settingsScreen(narrow: narrow)
        case .privacy: privacyScreen(narrow: narrow)
        case .models: modelsScreen(narrow: narrow)
        case .history:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pageHeading("history", subtitle: "history_subtitle")
                    ForEach(data.sessions) { session in historyRow(session, selected: false, active: session.id == 1 && currentMeetingState != .completed) }
                }.frame(maxWidth: 700).padding(narrow ? 20 : 32).frame(maxWidth: .infinity)
            }
        }
    }

    private func readyScreen(narrow: Bool, generous: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    tag("offline_meeting", icon: "mic")
                    Text(Copy.text("Be in the conversation.")).font(theme.font(.display))
                    Text(Copy.text("Record your meeting. Come back to every word.")).font(theme.font(.body)).foregroundStyle(theme.color("secondaryText"))
                }.padding(.top, generous ? 42 : 14)
                surface {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(Copy.text("meeting_title")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                        Text(data.sessions[0].title).font(theme.font(.title))
                        divider
                        infoLine("mic", title: "microphone", value: "built_in_mic")
                        infoLine("globe", title: "speech_languages", value: "ru_en")
                        infoLine("lock", title: "retention", value: saveAudio ? "audio_and_text" : "text_only")
                        Button { screen = .settings } label: { Label(Copy.text("change_settings"), systemImage: "slider.horizontal.3").font(theme.font(.body)) }
                            .buttonStyle(.plain).foregroundStyle(theme.accent).frame(minHeight: 44)
                    }
                }
                primaryButton("Start Recording", icon: "record.circle") { startMeetingPreview() }
                Text(Copy.text("local_capture_mobile_detail")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                Label(Copy.text("participant_consent"), systemImage: "person.2")
                    .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                Text(Copy.text("ready_mock_detail")).font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
            }
            .frame(maxWidth: generous ? 620 : 730)
            .padding(narrow ? 20 : 32)
            .frame(maxWidth: .infinity)
        }
    }

    private func meetingScreen(narrow: Bool, generous: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            meetingHeading(narrow: narrow, generous: generous)
                .padding(narrow ? 20 : 28)
            divider
            if screen == .active && (options.exportPath == nil || options.replayTime != nil) {
                PrototypeLiveTranscriptView(replay: replay, theme: theme, compact: narrow)
                    .padding(narrow ? 20 : 28)
            } else { ScrollView {
                VStack(alignment: .leading, spacing: generous ? 26 : 20) {
                    HStack {
                        Text(Copy.text(screen == .completed ? "Transcript" : "Live transcript")).font(theme.font(.section))
                        Spacer()
                        if !narrow { tag(screen == .completed ? "speaker_result" : "preliminary", icon: screen == .completed ? "person.2" : "text.bubble") }
                    }
                    ForEach(displayedUtterances) { utterance in
                        transcriptRow(utterance, narrow: narrow, generous: generous)
                    }
                    if screen == .active {
                        HStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                            Text(Copy.text(paused ? "paused_preview" : "listening_preview"))
                        }.font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
                        Text(Copy.text("speaker_after_recording"))
                            .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(narrow ? 20 : generous ? 38 : 28)
            } }
            divider
            meetingControls(narrow: narrow)
                .padding(narrow ? 16 : 24)
                .background(theme.color("toolbarBackground"))
        }
        .background(theme.color("cardBackground"))
    }

    private func processingScreen(narrow: Bool) -> some View {
        let stages = ["Saving", "Identifying speakers", "Transcribing", "Finalizing"]
        return VStack(alignment: .leading, spacing: 24) {
            Label(Copy.text("Preparing your transcript"), systemImage: "hourglass")
                .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
            Text(data.sessions[0].title).font(theme.font(.display))
            Text(Copy.text("processing_mobile_detail")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
            divider
            ForEach(stages.indices, id: \.self) { index in
                HStack(spacing: 16) {
                    Image(systemName: index < processingIndex ? "checkmark.circle.fill" : index == processingIndex ? "circle.dotted" : "circle")
                        .foregroundStyle(index < processingIndex ? theme.color("success") : theme.accent)
                    Text(Copy.text(stages[index])).font(theme.font(.body, weight: .medium))
                }.frame(minHeight: 44)
            }
            Spacer()
        }.padding(narrow ? 20 : 32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func meetingHeading(narrow: Bool, generous: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                tag(screen == .completed ? "completed" : paused ? "paused" : "Recording", icon: screen == .completed ? "checkmark.circle" : "record.circle")
                Spacer()
                Text(screen == .active && (options.exportPath == nil || options.replayTime != nil) ? elapsedReplayText : completedDurationText)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .monospacedDigit()
            }
            Text(displayedSession.title).font(theme.font(narrow ? .title : .display))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Label(Copy.text("In-room meeting"), systemImage: "person.2")
                if !narrow { Text("•"); Text(displayedSession.time) }
            }.font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
            HStack(spacing: 8) {
                tag(saveAudio ? "audio_and_text" : "text_only", icon: "lock")
                if !narrow { tag("local_only", icon: "ipad") }
            }
            if screen == .completed {
                Text(Copy.text("Speaker labels are automatic and may not be exact. Click a name to fix it."))
                    .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
            } else {
                Label(Copy.text("Microphone"), systemImage: "mic")
                    .font(theme.font(.caption)).foregroundStyle(theme.accent)
            }
        }
    }

    private var elapsedReplayText: String {
        let seconds = Int(replay.currentTime)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var completedDurationText: String {
        guard screen == .completed, selectedSessionID == 1, let time = completedReplayDuration else { return displayedSession.duration }
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var displayedUtterances: [SyntheticFixtures.Utterance] {
        guard screen == .completed, selectedSessionID == 1, completedReplayDuration != nil else { return data.utterances }
        return replay.snapshot.utterances.enumerated().map { index, utterance in
            let seconds = Int(utterance.start)
            return .init(id: index, time: String(format: "%02d:%02d", seconds / 60, seconds % 60), owner: true, text: utterance.text)
        }
    }

    private func transcriptRow(_ utterance: SyntheticFixtures.Utterance, narrow: Bool, generous: Bool) -> some View {
        HStack(alignment: .top, spacing: narrow ? 12 : 18) {
            if !narrow {
                Text(utterance.time).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.color("tertiaryText"))
                    .frame(width: 48, alignment: .leading).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(screen == .completed ? PichiLocalization.format("Speaker %lld", Int64(utterance.owner ? 1 : 2)) : Copy.text("Microphone"))
                        .font(theme.font(.caption, weight: .semibold))
                        .foregroundStyle(screen == .completed && utterance.owner ? theme.accent : theme.color("secondaryText"))
                    if narrow { Text(utterance.time).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.color("tertiaryText")) }
                    if screen == .completed && !narrow {
                        Spacer()
                        Button { showCopy = true } label: { Label(Copy.text("action.edit"), systemImage: "pencil").font(theme.font(.caption)).frame(minHeight: 44) }
                            .buttonStyle(.plain).foregroundStyle(theme.accent)
                        if saveAudio {
                            Button { showCopy = true } label: { Label(Copy.text("Audio"), systemImage: "play.fill").font(theme.font(.caption)).frame(minHeight: 44) }
                                .buttonStyle(.plain).foregroundStyle(theme.accent)
                        }
                    }
                }
                Text(utterance.text)
                    .font(theme.font(.body))
                    .lineSpacing(generous ? 7 : 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, generous ? 4 : 0)
    }

    private func meetingControls(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
          if screen == .active {
            Text(Copy.text("Speaker labels are added after recording."))
                .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
          }
          HStack(spacing: 12) {
            if screen == .completed {
                primaryButton("Copy", icon: "doc.on.doc") { showCopy = true }
                secondaryButton("More", icon: "ellipsis") { showExport = true }
            } else {
                primaryButton("Stop & Transcribe", icon: "stop.fill") { finishMeetingPreview() }
            }
          }
        }
    }

    private func dashboardCurrent(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { caption(screen == .completed ? "last_meeting" : "current_meeting"); Spacer(); tag(screen == .ready ? "ready" : screen == .completed ? "completed" : "recording", icon: "mic") }
            Text(displayedSession.title).font(theme.font(.title))
            if screen == .ready {
                Text(Copy.text("ready_subtitle")).foregroundStyle(theme.color("secondaryText"))
                primaryButton("Start Recording", icon: "record.circle") { startMeetingPreview() }
            } else {
                HStack(spacing: 20) {
                    Text(displayedSession.duration).font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Copy.text("offline_meeting")).font(theme.font(.caption))
                        Text(Copy.text(saveAudio ? "audio_and_text" : "text_only")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                    }
                }
                divider
                Text(Copy.text(screen == .completed ? "transcript" : "live_transcript")).font(theme.font(.section))
                ForEach(data.utterances.prefix(2)) { utterance in transcriptRow(utterance, narrow: narrow, generous: false) }
                Text(Copy.text(screen == .completed ? "completed_mock_detail" : "live_preliminary_short")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                meetingControls(narrow: narrow)
            }
        }
        .padding(24)
        .background(theme.color("cardBackground"), in: RoundedRectangle(cornerRadius: theme.radius))
        .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.color("cardBorder"), lineWidth: 1))
    }

    private var dashboardHistory: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(Copy.text("recent")).font(theme.font(.section)); Spacer(); Image(systemName: "clock").foregroundStyle(theme.accent) }
            ForEach(data.sessions.dropFirst().prefix(2)) { session in historyRow(session, selected: false, active: false) }
            surface {
                VStack(alignment: .leading, spacing: 12) {
                    Label(Copy.text("device_storage"), systemImage: "internaldrive").font(theme.font(.section))
                    Text(Copy.text("device_storage_detail")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                    Button { screen = .settings } label: { Text(Copy.text("settings")).font(theme.font(.body)).frame(minHeight: 44) }
                        .buttonStyle(.plain).foregroundStyle(theme.accent)
                }
            }
        }
    }

    private func settingsScreen(narrow: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeading("settings", subtitle: "settings_subtitle")
                surface {
                    VStack(spacing: 20) {
                        settingsDestination("models", detail: "models_subtitle", icon: "square.stack.3d.up", destination: .models)
                        divider
                        settingsDestination("privacy", detail: "privacy_subtitle", icon: "hand.raised", destination: .privacy)
                    }
                }
            }.frame(maxWidth: 760).padding(narrow ? 20 : 32).frame(maxWidth: .infinity)
        }
    }

    private func settingsDestination(_ title: String, detail: String, icon: String, destination: PrototypeScreen) -> some View {
        Button { screen = destination } label: {
            HStack(spacing: 16) {
                tileIcon(icon)
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.text(title)).font(theme.font(.section)).foregroundStyle(theme.color("primaryText"))
                    Text(Copy.text(detail)).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(theme.accent)
            }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func privacyScreen(narrow: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeading("privacy", subtitle: "privacy_subtitle")
                surface {
                    VStack(alignment: .leading, spacing: 20) {
                        settingRow("save_audio", description: "save_audio_detail", icon: "waveform", value: $saveAudio, narrow: narrow)
                        divider
                        Label(Copy.text(saveAudio ? "audio_and_text_detail" : "text_only_detail"), systemImage: "lock.shield")
                            .font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                surface {
                    VStack(alignment: .leading, spacing: 20) {
                        settingRow("recognize_speakers", description: "recognize_speakers_detail", icon: "person.2", value: $diarization, narrow: narrow)
                        divider
                        HStack(alignment: .top, spacing: 16) {
                            tileIcon("person.crop.circle")
                            VStack(alignment: .leading, spacing: 10) {
                                Text(Copy.text("my_voice")).font(theme.font(.section))
                                Text(Copy.text("my_voice_detail")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                                Button { showEnrollment = true } label: { Label(Copy.text("setup_voice"), systemImage: "arrow.right").font(theme.font(.body)).frame(minHeight: 44) }
                                    .buttonStyle(.plain).foregroundStyle(theme.accent)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                surface { settingRow("add_place", description: "add_place_detail", icon: "location", value: $includePlace, narrow: narrow) }
                Text(Copy.text("privacy_mock_detail")).font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
            }.frame(maxWidth: 760).padding(narrow ? 20 : 32).frame(maxWidth: .infinity)
        }
    }

    private func modelsScreen(narrow: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeading("models", subtitle: "models_subtitle")
                surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(Copy.text("benchmark_needed"), systemImage: "ipad").font(theme.font(.section))
                        Text(Copy.text("benchmark_detail")).font(theme.font(.body)).foregroundStyle(theme.color("secondaryText"))
                    }
                }
                ForEach(data.speechModels) { model in
                    modelCard(name: model.name, subtitle: model.detailKey, icon: model.symbol, language: model.languageKey, size: model.size)
                }
                Text(Copy.text("models_mock_detail")).font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
            }.frame(maxWidth: 760).padding(narrow ? 20 : 32).frame(maxWidth: .infinity)
        }
    }

    private func modelCard(name: String, subtitle: String, icon: String, language: String, size: String) -> some View {
        surface {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    tileIcon(icon)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(name).font(theme.font(.title))
                        Text(Copy.text(language)).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                    }
                    Spacer()
                }
                Text(Copy.text(subtitle)).font(theme.font(.body)).foregroundStyle(theme.color("secondaryText"))
                Text(size).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                HStack { tag("candidate", icon: "flask"); Spacer() }
                secondaryButton("device_validation", icon: "arrow.down.circle") { showValidation = true }
            }
        }
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            bottomItem("meetings", icon: "waveform", selected: isMeeting) { showCurrentMeeting() }
            bottomItem("history", icon: "clock", selected: screen == .history) { screen = .history }
            bottomItem("settings", icon: "gearshape", selected: isSettings) { screen = .settings }
        }
        .frame(height: 76)
        .background(theme.color("toolbarBackground"))
    }

    private func bottomItem(_ key: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 21, weight: selected ? .semibold : .regular))
                Text(Copy.text(key)).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? theme.accent : theme.color("secondaryText"))
            .frame(maxWidth: .infinity, minHeight: 60)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Copy.text(key))
    }

    private func navRow(_ key: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).font(.system(size: 18))
                Text(Copy.text(key)).font(theme.font(.caption, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? theme.color("accentForeground") : theme.color("primaryText"))
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(selected ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private func iconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 44, height: 44)
                .foregroundStyle(theme.accent)
                .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Copy.text(label))
    }

    private func primaryButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(Copy.text(key), systemImage: icon)
                .font(theme.font(.body, weight: .semibold)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 14)
                .foregroundStyle(theme.color("accentForeground"))
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func secondaryButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(Copy.text(key), systemImage: icon)
                .font(theme.font(.body, weight: .medium)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 12)
                .foregroundStyle(theme.accent)
                .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.color("cardBorder"), lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func caption(_ key: String) -> some View {
        Text(Copy.text(key)).font(theme.font(.caption, weight: .semibold)).foregroundStyle(theme.color("secondaryText"))
    }

    private func tag(_ key: String, icon: String) -> some View {
        Label(Copy.text(key), systemImage: icon).font(theme.font(.caption, weight: .medium))
            .foregroundStyle(theme.accent).padding(.horizontal, 10).padding(.vertical, 7)
            .background(theme.accent.opacity(options.dark ? 0.15 : 0.08), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    private func surface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(theme.color("cardBackground"), in: RoundedRectangle(cornerRadius: theme.radius))
            .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.color("cardBorder"), lineWidth: 1))
    }

    private func tileIcon(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 22)).foregroundStyle(theme.accent).frame(width: 48, height: 48)
            .background(theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }

    private func infoLine(_ icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.text(title)).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                Text(Copy.text(value)).font(theme.font(.body))
            }
        }
    }

    private func pageHeading(_ key: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.text(key)).font(theme.font(.display))
            Text(Copy.text(subtitle)).font(theme.font(.body)).foregroundStyle(theme.color("secondaryText"))
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 6)
    }

    private func settingRow(_ key: String, description: String, icon: String, value: Binding<Bool>, narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                tileIcon(icon)
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.text(key)).font(theme.font(.section))
                    if !narrow {
                        Text(Copy.text(description)).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Toggle(Copy.text(key), isOn: value).labelsHidden().toggleStyle(.switch)
                    .frame(minWidth: 52, minHeight: 44).accessibilityLabel(Copy.text(key))
            }
            if narrow {
                Text(Copy.text(description)).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sheetHeader(_ key: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(Copy.text(key)).font(theme.font(.title))
            Spacer()
            iconButton("xmark", label: "close", action: action)
        }.padding(20)
    }

    private var enrollmentSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader("my_voice") { showEnrollment = false }
            ScrollView {
              VStack(alignment: .leading, spacing: 24) {
                tileIcon("person.wave.2")
                Text(Copy.text("enrollment_title")).font(theme.font(.display))
                Text(Copy.text("enrollment_detail")).font(theme.font(.body)).foregroundStyle(theme.color("secondaryText"))
                surface { Text(Copy.text("enrollment_phrase")).font(theme.font(.title)).lineSpacing(6) }
                Text(Copy.text("enrollment_privacy")).font(theme.font(.caption)).foregroundStyle(theme.color("secondaryText"))
                primaryButton("enrollment_continue", icon: "checkmark") { showEnrollment = false }
                Text(Copy.text("enrollment_mock")).font(theme.font(.caption)).foregroundStyle(theme.color("tertiaryText"))
              }.padding(24)
            }
        }
        .frame(minWidth: 320, idealWidth: 580, maxWidth: 580, minHeight: 400, idealHeight: 700)
        .background(theme.color("windowBackground"))
        .foregroundStyle(theme.color("primaryText"))
    }
}
