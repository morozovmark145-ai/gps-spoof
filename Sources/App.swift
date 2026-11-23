import SwiftUI
import MapKit
import UniformTypeIdentifiers

@main
struct GPSSpoofApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
}

@MainActor
final class Model: ObservableObject {
    @Published var pin: CLLocationCoordinate2D?
    @Published var active: CLLocationCoordinate2D?
    @Published var busy = false
    @Published var status = "Готово"
    @Published var isError = false
    @Published var hasPairing = LocationEngine.hasPairingFile
    @Published var favorites: [Favorite] = []

    let engine = LocationEngine()
    private let keepAlive = KeepAlive()
    private let favKey = "favorites"

    init() {
        if let d = UserDefaults.standard.data(forKey: favKey),
           let f = try? JSONDecoder().decode([Favorite].self, from: d) {
            favorites = f
        }
    }

    func teleport() {
        guard let p = pin else { return report("Сначала поставьте точку на карте", error: true) }
        busy = true
        status = "Подключение..."
        keepAlive.start()
        engine.set(lat: p.latitude, lon: p.longitude) { [weak self] r in
            guard let self else { return }
            self.busy = false
            switch r {
            case .success:
                self.active = p
                self.report(String(format: "Активно: %.6f, %.6f", p.latitude, p.longitude))
            case .failure(let e):
                self.report(e.description, error: true)
            }
        }
    }

    func stop() {
        busy = true
        engine.clear { [weak self] r in
            guard let self else { return }
            self.busy = false
            self.active = nil
            self.keepAlive.stop()
            if case .failure(let e) = r { self.report("Сброс: " + e.description, error: true) }
            else { self.report("Настоящая геопозиция возвращена") }
        }
    }

    func importPairing(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let kind = try LocationEngine.importPairing(data)
            hasPairing = true
            report("Импортирован: \(kind)")
        } catch let e as EngineError {
            report("Не удалось импортировать: \(e.description)", error: true)
        } catch {
            report("Не удалось импортировать: \(error.localizedDescription)", error: true)
        }
    }

    func refreshPairing() {
        hasPairing = LocationEngine.hasPairingFile
    }

    func addFavorite(name: String) {
        guard let p = pin else { return }
        favorites.append(Favorite(name: name, lat: p.latitude, lon: p.longitude))
        saveFavs()
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        saveFavs()
    }

    private func saveFavs() {
        if let d = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(d, forKey: favKey) }
    }

    func report(_ s: String, error: Bool = false) {
        status = s
        isError = error
    }
}

struct ContentView: View {
    @StateObject private var m = Model()
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)))
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var showSettings = false
    @State private var showFavs = false
    @State private var showCoords = false
    @State private var latText = ""
    @State private var lonText = ""
    @State private var favName = ""
    @State private var askFavName = false

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $camera) {
                    if let p = m.pin {
                        Marker("Точка", coordinate: p).tint(.blue)
                    }
                    if let a = m.active {
                        Annotation("Активно", coordinate: a) {
                            Circle().fill(.green.opacity(0.7)).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .onTapGesture { pt in
                    if let c = proxy.convert(pt, from: .local) { m.pin = c }
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                searchBar
                if !results.isEmpty { resultList }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            VStack { Spacer(); bottomPanel }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { m.refreshPairing() } }
        .onOpenURL { m.importPairing($0) }
        .sheet(isPresented: $showSettings) { SettingsView(m: m) }
        .sheet(isPresented: $showFavs) { favSheet }
        .alert("Координаты", isPresented: $showCoords) {
            TextField("Широта", text: $latText).keyboardType(.numbersAndPunctuation)
            TextField("Долгота", text: $lonText).keyboardType(.numbersAndPunctuation)
            Button("Поставить") { applyCoords() }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Название", isPresented: $askFavName) {
            TextField("Например, Дом", text: $favName)
            Button("Сохранить") { m.addFavorite(name: favName.isEmpty ? "Точка" : favName); favName = "" }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Город, адрес, место", text: $query)
                .submitLabel(.search)
                .onSubmit(search)
            if !query.isEmpty {
                Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
            }
            Button { showSettings = true } label: {
                Image(systemName: m.hasPairing ? "gearshape" : "exclamationmark.triangle.fill")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(results, id: \.self) { item in
                Button {
                    let c = item.placemark.coordinate
                    m.pin = c
                    camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2000, longitudinalMeters: 2000))
                    results = []
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "").font(.body)
                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(m.active != nil ? .green : .gray).frame(width: 8, height: 8)
                Text(m.status).font(.footnote).foregroundStyle(m.isError ? .red : .primary).lineLimit(6)
                    .textSelection(.enabled)
                Spacer()
                if m.busy { ProgressView() }
            }
            if let p = m.pin {
                Text(String(format: "Точка: %.6f, %.6f", p.latitude, p.longitude))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button { m.teleport() } label: {
                    Label("Телепорт", systemImage: "location.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.busy || m.pin == nil)

                Button { m.stop() } label: {
                    Label("Сброс", systemImage: "location.slash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(m.busy)
            }
            HStack(spacing: 8) {
                Button { showCoords = true } label: { Label("Координаты", systemImage: "number") }
                Spacer()
                Button { askFavName = true } label: { Image(systemName: "star") }.disabled(m.pin == nil)
                Button { showFavs = true } label: { Label("Избранное", systemImage: "list.star") }
            }
            .font(.footnote)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var favSheet: some View {
        NavigationStack {
            List {
                if m.favorites.isEmpty { Text("Пусто. Поставьте точку и нажмите ☆.").foregroundStyle(.secondary) }
                ForEach(m.favorites) { f in
                    Button {
                        let c = CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon)
                        m.pin = c
                        camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2000, longitudinalMeters: 2000))
                        showFavs = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text(String(format: "%.5f, %.5f", f.lat, f.lon)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { m.removeFavorites(at: $0) }
            }
            .navigationTitle("Избранное")
            .toolbar { Button("Готово") { showFavs = false } }
        }
    }

    private func search() {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        MKLocalSearch(request: req).start { resp, _ in
            results = Array((resp?.mapItems ?? []).prefix(6))
            if results.isEmpty { m.report("Ничего не найдено", error: true) }
        }
    }

    private func applyCoords() {
        let lat = Double(latText.replacingOccurrences(of: ",", with: "."))
        let lon = Double(lonText.replacingOccurrences(of: ",", with: "."))
        guard let lat, let lon, abs(lat) <= 90, abs(lon) <= 180 else {
            return m.report("Неверные координаты", error: true)
        }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        m.pin = c
        camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2000, longitudinalMeters: 2000))
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing-файл") {
                    HStack {
                        Image(systemName: m.hasPairing ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(m.hasPairing ? .green : .red)
                        Text(m.hasPairing ? "Импортирован" : "Не импортирован")
                    }
                    Button("Выбрать файл (.plist / .mobiledevicepairing)") { importing = true }
                }
                Section("Как настроить") {
                    Text("1. Включите Режим разработчика: Настройки → Конфиденциальность и безопасность.")
                    Text("2. На ПК создайте pairing-файл программой idevice_pair (iDevicePair) и перекиньте его на iPhone.")
                    Text("3. Импортируйте файл здесь.")
                    Text("4. Установите LocalDevVPN из App Store и включите его.")
                    Text("5. Поставьте точку на карте и нажмите «Телепорт».")
                }
                .font(.footnote)
                Section("Требования") {
                    Text("iOS 17.4 и новее. Приложение держится в фоне через геолокацию, разрешите «Всегда».")
                        .font(.footnote)
                }
            }
            .navigationTitle("Настройки")
            .toolbar { Button("Готово") { dismiss() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data, .item]) { r in
                if case .success(let url) = r { m.importPairing(url) }
            }
        }
    }
}
