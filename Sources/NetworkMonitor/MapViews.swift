import MapKit
import SwiftUI

/// Small static map centered on one server location, shown in the inspector.
/// Reuses a single map view across selections and just moves the camera —
/// recreating the MKMapView per click (e.g. via `.id`) is expensive enough to
/// make row selection feel laggy.
struct FlowMiniMap: View {
    let coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        _position = State(initialValue: .region(Self.region(for: coordinate)))
    }

    var body: some View {
        Map(position: $position, interactionModes: []) {
            Marker("", coordinate: coordinate)
                .tint(.red)
        }
        .mapStyle(.standard(elevation: .flat))
        .onChange(of: "\(coordinate.latitude),\(coordinate.longitude)") {
            position = .region(Self.region(for: coordinate))
        }
    }

    private static func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12))
    }
}

/// World map plotting every active flow's estimated server location. Nearby
/// servers are clustered to one pin with a count, sized by connection volume.
struct FlowsMapView: View {
    let rows: [FlowRow]

    private struct Cluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let label: String
        let count: Int
    }

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 25, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 160)
        ))) {
            ForEach(clusters) { cluster in
                Annotation(cluster.label, coordinate: cluster.coordinate) {
                    ZStack {
                        Circle()
                            .fill(.red.gradient)
                            .frame(width: pinSize(cluster.count), height: pinSize(cluster.count))
                        if cluster.count > 1 {
                            Text("\(cluster.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .help("\(cluster.label) — \(cluster.count) connection\(cluster.count == 1 ? "" : "s")")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .overlay(alignment: .bottomTrailing) {
            if clusters.isEmpty {
                Text("No located connections yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
        }
    }

    private func pinSize(_ count: Int) -> CGFloat {
        min(44, 16 + CGFloat(count).squareRoot() * 4)
    }

    /// Buckets servers onto a ~1° grid so a city's many flows render as one pin.
    private var clusters: [Cluster] {
        var buckets: [String: (lat: Double, lon: Double, count: Int, label: String)] = [:]
        for row in rows {
            guard let location = row.location else { continue }
            let key = "\(Int(location.latitude.rounded()))_\(Int(location.longitude.rounded()))"
            let label = row.regionDisplay ?? row.remoteDisplay
            if var existing = buckets[key] {
                existing.count += row.count
                buckets[key] = existing
            } else {
                buckets[key] = (location.latitude, location.longitude, row.count, label)
            }
        }
        return buckets.map { key, value in
            Cluster(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: value.lat, longitude: value.lon),
                label: value.label,
                count: value.count
            )
        }
    }
}
