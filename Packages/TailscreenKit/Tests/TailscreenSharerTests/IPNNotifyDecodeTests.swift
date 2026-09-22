import Foundation
import TailscaleKit
import XCTest

/// The fork's `Ipn.Notify` Codable models against the JSON the pinned
/// tailscale.com (`go.mod` in the libtailscale submodule) actually emits.
///
/// Swift's synthesized `Decodable` treats every non-optional stored property
/// as a *required* key, defaults notwithstanding — so a field Go stops
/// emitting (removed, or `omitzero`/`omitempty` and empty) fails the whole
/// message, and `MessageProcessor` drops it with one log line. That is how
/// the `.initialState` notify, the one message every subscription starts
/// with, was silently lost for a release: `Prefs.AllowSingleHosts` had been
/// gone from `ipn.Prefs` for years. These fixtures are the current Go field
/// sets; a future bump that drops another key fails here rather than in a
/// bundle.
final class IPNNotifyDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> Ipn.Notify {
        try JSONDecoder().decode(Ipn.Notify.self, from: Data(json.utf8))
    }

    /// The initial-state notify: `Prefs` in the v1.102.3 shape, which has no
    /// `AllowSingleHosts`, alongside `State` and `Version`.
    func testInitialStateNotifyWithCurrentPrefsDecodes() throws {
        let notify = try decode(Self.initialStateJSON)
        let prefs = try XCTUnwrap(notify.Prefs)
        XCTAssertNil(prefs.AllowSingleHosts)
        XCTAssertEqual(prefs.ControlURL, "https://controlplane.tailscale.com")
        XCTAssertTrue(prefs.WantRunning)
        XCTAssertEqual(prefs.Hostname, "tailscreen-mac")
        XCTAssertEqual(prefs.ExitNodeID, "")
        XCTAssertNil(prefs.ForceDaemon, "omitempty on the Go side: absent when false")
        XCTAssertEqual(notify.State, .Running)
        XCTAssertEqual(notify.Version, "1.102.3")
    }

    /// A peer whose `Hostinfo`, `ComputedName` and `ComputedNameWithHost`
    /// are all `omitzero`-elided must not fail the netmap.
    func testNodeWithOmittedZeroFieldsDecodes() throws {
        let notify = try decode(Self.sparseNetmapJSON)
        let peers = try XCTUnwrap(notify.NetMap?.Peers)
        XCTAssertEqual(peers.count, 1)
        let peer = peers[0]
        XCTAssertEqual(peer.ID, 9)
        XCTAssertEqual(peer.ComputedName, "")
        XCTAssertEqual(peer.ComputedNameWithHost, "")
        XCTAssertNil(peer.Hostinfo.Hostname)
        XCTAssertNil(peer.Online)
        XCTAssertNil(peer.Tags)
    }

    /// The fully populated node still round-trips: the custom decoder reads
    /// every key the synthesized one did.
    func testFullNodeDecodesEveryField() throws {
        let notify = try decode(Self.fullNetmapJSON)
        let peer = try XCTUnwrap(notify.NetMap?.Peers?.first)
        XCTAssertEqual(peer.StableID, "nPEER")
        XCTAssertEqual(peer.Name, "studio.tail.ts.net.")
        XCTAssertEqual(peer.User, 100)
        XCTAssertEqual(peer.Sharer, 200)
        XCTAssertEqual(peer.Key, "nodekey:07")
        XCTAssertEqual(peer.KeyExpiry, "2030-01-01T00:00:00Z")
        XCTAssertEqual(peer.Addresses, ["100.64.0.7/32"])
        XCTAssertEqual(peer.AllowedIPs, ["100.64.0.7/32", "0.0.0.0/0", "::/0"])
        XCTAssertTrue(peer.IsExitNode)
        XCTAssertEqual(peer.Hostinfo.OS, "linux")
        XCTAssertEqual(peer.LastSeen, "2026-09-20T10:00:00Z")
        XCTAssertEqual(peer.Online, true)
        XCTAssertEqual(peer.Capabilities, ["https://tailscale.com/cap/is-admin"])
        XCTAssertTrue(peer.isAdmin)
        XCTAssertEqual(peer.Tags, ["tag:studio"])
        XCTAssertEqual(peer.ComputedName, "studio")
        XCTAssertEqual(peer.ComputedNameWithHost, "studio (studio-host)")
        XCTAssertEqual(notify.NetMap?.SelfNode.ComputedName, "me")
        XCTAssertEqual(notify.NetMap?.currentUserProfile()?.LoginName, "a@example.com")
    }

    /// Engine and browse-to-URL notifies, the other two payloads the watcher
    /// subscribes to.
    func testEngineAndBrowseToURLNotifiesDecode() throws {
        let engine = try decode(
            #"""
            {"Version":"1.102.3","Engine":{"RBytes":10,"WBytes":20,"NumLive":1,"LiveDERPs":1,
             "LivePeers":{"nodekey:07":{"NodeKey":"nodekey:07","TxBytes":1,"RxBytes":2,
             "LastHandshake":"2026-09-20T10:00:00Z"}}}}
            """#)
        XCTAssertEqual(engine.Engine?.NumLive, 1)
        XCTAssertEqual(engine.Engine?.LivePeers["nodekey:07"]?.RxBytes, 2)

        let browse = try decode(#"{"Version":"1.102.3","BrowseToURL":"https://login.tailscale.com/a/x"}"#)
        XCTAssertEqual(browse.BrowseToURL, "https://login.tailscale.com/a/x")
    }

    // MARK: Fixtures

    /// `ipn.Prefs` as tailscale.com v1.102.3 marshals it (every field the
    /// Swift model reads, plus the ones it ignores, minus the `omitempty`
    /// ones that are empty).
    static let initialStateJSON = #"""
        {
          "Version": "1.102.3",
          "State": 6,
          "Prefs": {
            "ControlURL": "https://controlplane.tailscale.com",
            "RouteAll": false,
            "ExitNodeID": "",
            "ExitNodeIP": "",
            "InternalExitNodePrior": "",
            "ExitNodeAllowLANAccess": false,
            "CorpDNS": true,
            "RunSSH": false,
            "RunWebClient": false,
            "WantRunning": true,
            "LoggedOut": false,
            "ShieldsUp": false,
            "AdvertiseTags": null,
            "Hostname": "tailscreen-mac",
            "NotepadURLs": false,
            "AdvertiseRoutes": null,
            "AdvertiseServices": null,
            "Sync": "",
            "NoSNAT": false,
            "NetfilterMode": 2,
            "AutoUpdate": {"Check": true, "Apply": null},
            "AppConnector": {"Advertise": false},
            "PostureChecking": false,
            "NetfilterKind": "",
            "RemoteConfig": false,
            "DriveShares": null,
            "Config": null
          }
        }
        """#

    static let sparseNetmapJSON = #"""
        {
          "Version": "1.102.3",
          "NetMap": {
            "SelfNode": {
              "ID": 1, "StableID": "nSELF", "Name": "me.tail.ts.net.", "User": 100,
              "Key": "nodekey:00", "Addresses": ["100.64.0.1/32"],
              "Hostinfo": {"OS": "macOS", "Hostname": "me"},
              "ComputedName": "me", "ComputedNameWithHost": "me"
            },
            "NodeKey": "nodekey:00",
            "Peers": [
              {"ID": 9, "StableID": "nBARE", "Name": "", "User": 100,
               "Key": "nodekey:09", "Addresses": ["100.64.0.9/32"]}
            ],
            "DNS": {},
            "Domain": "example.com",
            "UserProfiles": {"100": {"ID": 100, "LoginName": "a@example.com", "DisplayName": "A"}}
          }
        }
        """#

    static let fullNetmapJSON = #"""
        {
          "Version": "1.102.3",
          "NetMap": {
            "SelfNode": {
              "ID": 1, "StableID": "nSELF", "Name": "me.tail.ts.net.", "User": 100,
              "Key": "nodekey:00", "Addresses": ["100.64.0.1/32"],
              "Hostinfo": {"OS": "macOS", "Hostname": "me"},
              "ComputedName": "me", "ComputedNameWithHost": "me"
            },
            "NodeKey": "nodekey:00",
            "Peers": [
              {
                "ID": 7, "StableID": "nPEER", "Name": "studio.tail.ts.net.", "User": 100,
                "Sharer": 200, "Key": "nodekey:07", "KeyExpiry": "2030-01-01T00:00:00Z",
                "Addresses": ["100.64.0.7/32"],
                "AllowedIPs": ["100.64.0.7/32", "0.0.0.0/0", "::/0"],
                "Hostinfo": {"OS": "linux", "OSVersion": "24.04", "Hostname": "studio-host"},
                "Tags": ["tag:studio"],
                "LastSeen": "2026-09-20T10:00:00Z",
                "Online": true,
                "Capabilities": ["https://tailscale.com/cap/is-admin"],
                "ComputedName": "studio", "ComputedNameWithHost": "studio (studio-host)"
              }
            ],
            "DNS": {"Domains": ["tail.ts.net"]},
            "Domain": "example.com",
            "UserProfiles": {
              "100": {"ID": 100, "LoginName": "a@example.com", "DisplayName": "A", "ProfilePicURL": ""},
              "200": {"ID": 200, "LoginName": "b@example.com", "DisplayName": "B"}
            }
          }
        }
        """#
}
