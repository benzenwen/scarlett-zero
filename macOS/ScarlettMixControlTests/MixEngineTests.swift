import Foundation
import Testing

struct GainTests {
    @Test func rawRoundTrip() {
        #expect(Gain.raw(0) == 0)
        #expect(Gain.raw(-10) == -2560)
        #expect(Gain.raw(nil) == Gain.silenceRaw)
        #expect(Gain.raw(-200) == Gain.silenceRaw)
        #expect(Gain.raw(12) == 1536)              // clamped to +6
        #expect(Gain.raw(3, ceiling: 0) == 0)       // bus volumes cap at 0 dB
        #expect(Gain.dB(-2560) == -10)
        #expect(Gain.dB(Gain.silenceRaw) == nil)
    }

    @Test func taperIsMonotonicAndInvertible() {
        var last = -Double.infinity
        for i in 1...100 {
            let p = Double(i) / 100
            let d = FaderTaper.dB(at: p)!
            #expect(d >= last)
            last = d
            #expect(abs(FaderTaper.position(for: d) - p) < 1e-9)
        }
        #expect(FaderTaper.dB(at: 0) == nil)
        #expect(FaderTaper.dB(at: 0.8) == 0)
        #expect(FaderTaper.dB(at: 1) == 6)
    }

    @Test func mixControlFaderLawAnchors() {
        #expect(MixControlFaderLaw.dB(0) == nil)
        #expect(abs(MixControlFaderLaw.dB(0.775137)!) < 0.01)
        #expect(abs(MixControlFaderLaw.dB(1)! - 6) < 0.01)
    }

    @Test func balanceLaw() {
        let c = PanLaw.balance(0)
        #expect(c.left == 0 && c.right == 0)
        let l = PanLaw.balance(-1)
        #expect(l.left == 0 && l.right == nil)
        let half = PanLaw.balance(0.5)
        #expect(half.right == 0)
        #expect(abs(half.left! - (-6.0206)) < 0.001)
    }
}

struct MixEngineTests {
    private func node(_ c: Int, _ b: Int) -> Int { HardwareImage.node(input: c, bus: b) }

    @Test func monoMixSumsChannelAndMixFader() {
        var doc = MixerDocument.cleared
        doc.mixes[2].gainDB = -6
        doc.mixes[2].channels[4].gainDB = -3
        let m = MixEngine.matrix(for: doc)
        #expect(m[node(4, 2)] == Gain.raw(-9))
        #expect(m[node(4, 3)] == Gain.silenceRaw)
        #expect(m[node(5, 2)] == Gain.silenceRaw)
    }

    @Test func stereoMixPansMonoChannel() {
        var doc = MixerDocument.cleared
        doc.setStereo(true, mixPair: 0)
        doc.mixes[0].gainDB = 0
        doc.mixes[0].channels[0] = .init(gainDB: 0, pan: -1)
        let m = MixEngine.matrix(for: doc)
        #expect(m[node(0, 0)] == 0)
        #expect(m[node(0, 1)] == Gain.silenceRaw)
    }

    @Test func linkedPairStaysOnItsSide() {
        var doc = MixerDocument.cleared
        doc.setStereo(true, mixPair: 1)
        doc.setLinked(true, pair: 8)
        doc.mixes[2].gainDB = 0
        doc.mixes[2].channels[16].gainDB = -2
        // Channel 17's own settings are ignored: the pair uses the leader's.
        doc.mixes[2].channels[17].gainDB = nil
        let m = MixEngine.matrix(for: doc)
        #expect(m[node(16, 2)] == Gain.raw(-2))
        #expect(m[node(16, 3)] == Gain.silenceRaw)
        #expect(m[node(17, 3)] == Gain.raw(-2))
        #expect(m[node(17, 2)] == Gain.silenceRaw)
    }

    @Test func soloAndMute() {
        var doc = MixerDocument.cleared
        doc.mixes[0].gainDB = 0
        for c in 0..<4 { doc.mixes[0].channels[c].gainDB = 0 }
        doc.mixes[0].channels[1].solo = true
        doc.mixes[0].channels[2].solo = true
        doc.mixes[0].channels[2].mute = true
        let m = MixEngine.matrix(for: doc)
        #expect(m[node(0, 0)] == Gain.silenceRaw)   // not soloed
        #expect(m[node(1, 0)] == 0)                 // soloed
        #expect(m[node(2, 0)] == Gain.silenceRaw)   // soloed but muted
        doc.mixes[0].mute = true
        #expect(MixEngine.matrix(for: doc)[node(1, 0)] == Gain.silenceRaw)
    }

    @Test func listenOverridesMonitorRouting() {
        var doc = MixerDocument.factoryDefault
        doc.routing[0] = SourceID.daw0
        let strip = MixEngine.routing(for: doc, listen: .strip(3))
        #expect(strip[0] == SourceID.analog0 + 3 && strip[1] == SourceID.analog0 + 3)
        let linked = MixEngine.routing(for: doc, listen: .strip(16))
        #expect(linked[0] == SourceID.daw0 && linked[1] == SourceID.daw0 + 1)
        let mix = MixEngine.routing(for: doc, listen: .mix(2))
        #expect(mix[0] == SourceID.mix0 + 2 && mix[1] == SourceID.mix0 + 3)
        #expect(MixEngine.routing(for: doc, listen: nil)[0] == SourceID.daw0)
    }

    @Test func monitorSection() {
        var doc = MixerDocument.cleared
        doc.monitor.modes = [.controlled, .controlled, .muted, .fixed, .controlled,
                             .controlled, .fixed, .fixed, .fixed, .fixed]
        doc.monitor.levelDB = -20
        doc.passthroughBuses[0] = -512
        doc.passthroughBuses[15] = -1024
        var b = MixEngine.buses(for: doc)
        #expect(b[0] == -512 && b[15] == -1024)      // untouched
        #expect(b[1] == Gain.raw(-20))
        #expect(b[3] == Gain.silenceRaw)            // muted
        #expect(b[4] == 0)                          // fixed
        doc.monitor.dim = true
        doc.monitor.pad = true
        b = MixEngine.buses(for: doc)
        #expect(b[1] == Gain.raw(-58))              // −20 −18 dim −20 pad
        #expect(b[5] == Gain.raw(-38))              // pad only on outputs 1/2
        doc.monitor.muteLeft = true
        b = MixEngine.buses(for: doc)
        #expect(b[1] == Gain.silenceRaw && b[2] != Gain.silenceRaw)
        doc.monitor.mute = true
        #expect(MixEngine.buses(for: doc)[2] == Gain.silenceRaw)
        #expect(MixEngine.buses(for: doc)[4] == 0)  // fixed ignores mute
    }

    @Test func hardwareRoundTripsThroughDerivedDocument() {
        var hw = HardwareImage()
        hw.clock = 1
        hw.routing = [38, 39, 38, 39, 38, 39, 0, 1, 38, 39] + Array(repeating: 46, count: 10)
        hw.mixerInputs = Array(20...29) + Array(repeating: 46, count: 6) + [0, 1]
        hw.matrix = (0..<144).map { $0 % 3 == 0 ? Gain.silenceRaw : Int16(-($0 * 10)) }
        hw.buses = Array(repeating: 0, count: 21)
        hw.buses[1] = -2560
        hw.buses[2] = -2560
        hw.buses[3] = Gain.silenceRaw
        let doc = MixEngine.document(from: hw)
        #expect(MixEngine.matches(doc, hw))
        #expect(doc.monitor.modes[0] == .controlled && doc.monitor.modes[2] == .muted && doc.monitor.modes[3] == .fixed)
    }

    @Test func documentIsCodable() throws {
        var doc = MixerDocument.factoryDefault
        doc.inputs[0].name = "Vocal"
        doc.mixes[0].channels[3].pan = 0.25
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(MixerDocument.self, from: data)
        #expect(decoded == doc)
    }
}

struct StructureTests {
    @Test func slotsAndStrips() {
        var doc = MixerDocument.cleared
        doc.setStereo(true, mixPair: 1)
        #expect(doc.mixSlots.map(\.bus) == [0, 1, 2, 4, 5, 6, 7])
        #expect(doc.slot(containing: 3).bus == 2)
        doc.setLinked(true, pair: 0)
        #expect(doc.strips.count == 17)
        #expect(doc.stripLeader(1) == 0)
    }

    @Test func sourceLabels() {
        var doc = MixerDocument.cleared
        #expect(doc.sourceLabel(22) == "Anlg In 3")
        #expect(doc.sourceLabel(29) == "SPDIF R")
        #expect(doc.sourceLabel(33) == "ADAT In 4")
        #expect(doc.sourceLabel(46) == "Off")
        #expect(doc.sourceLabel(39) == "Mix 2")
        doc.setStereo(true, mixPair: 0)
        doc.mixes[0].name = "Cue"
        #expect(doc.sourceLabel(39) == "Cue (R)")
    }

    @Test func automaticMixNamesFollowStereoLink() {
        var doc = MixerDocument.cleared
        doc.mixes[0].name = "Mix 1+2"   // as imported from MixControl
        #expect(doc.mixName(doc.slot(containing: 0)) == "Mix 1")
        doc.setStereo(true, mixPair: 0)
        #expect(doc.mixName(doc.slot(containing: 0)) == "Mix 1+2")
        #expect(doc.sourceLabel(39) == "Mix 1+2 (R)")
        doc.mixes[0].name = "Cue"
        doc.setStereo(false, mixPair: 0)
        #expect(doc.mixName(doc.slot(containing: 0)) == "Cue")
        #expect(MixerDocument.isAutomaticMixName("Mix 3 + 4"))
        #expect(!MixerDocument.isAutomaticMixName("Mix Bob"))
    }

    @Test func presets() {
        var doc = MixerDocument.cleared
        RoutingPreset.mixing.apply(to: &doc)
        #expect(doc.routing[0] == 0 && doc.routing[9] == 9 && doc.routing[12] == 10 && doc.routing[11] == 19)
        RoutingPreset.dawTracking.apply(to: &doc)
        #expect(doc.routing[6] == 0 && doc.routing[7] == 1)
        MonitorPreset.quad.apply(to: &doc)
        #expect(doc.monitor.modes[6] == .controlled && doc.monitor.modes[2] == .muted)
        MonitorPreset.miniPhones2.apply(to: &doc)
        #expect(doc.monitor.modes[0] == .controlled && doc.monitor.modes[9] == .controlled)
        #expect(MixerDocument.factoryDefault.mixSlots.allSatisfy { $0.stereo })
    }
}

struct LegacySnapshotTests {
    // Hand-written in MixControl's `.18i20` format.
    static let xml = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <USB18i20Snapshot version="2" name="Test">
      <USB18i20Router version="3" active="4">
        <xpoints count="4">
          <xp ix="0">5 0 0 0</xp>
          <xp ix="1">3 4 1 2</xp>
          <xp ix="2">2 1 5 9</xp>
          <xp ix="3">0 0 3 0</xp>
        </xpoints>
      </USB18i20Router>
      <USB18i20Monitor version="3">
        <hwc>1</hwc>
        <monset>1 1 0 0 0 0 0 0 1 1 </monset>
        <gain pad="1">-12.000000</gain>
      </USB18i20Monitor>
      <USB18i20Mixer version="3" nummixes="8" numchans="18">
        <globals chanms="196608" busms="3">
          <mixips>
            <ip c="0" name="Kick">0 0</ip>
            <ip c="16" name="">3 0</ip>
            <ip c="17" name="">3 1</ip>
          </mixips>
        </globals>
        <mixes active="0">
          <mix m="0" mute="0" gain="0.775137" name="Band">
            <chans>
              <chan c="0" s="1" m="0" p="0.250000" b="0.500000" g="1.000000" />
              <chan c="16" s="0" m="1" p="0.500000" b="0.750000" g="0.775137" />
            </chans>
          </mix>
        </mixes>
      </USB18i20Mixer>
    </USB18i20Snapshot>
    """

    @Test func importsSnapshot() throws {
        let doc = try LegacySnapshot.load(Data(Self.xml.utf8))
        #expect(doc.routing[0] == SourceID.mix0)
        #expect(doc.routing[14] == SourceID.daw0 + 4)       // ADAT out 3
        #expect(doc.inputs[9].source == SourceID.spdif0 + 1)
        #expect(doc.inputs[0].name == "Kick")
        #expect(doc.inputs[17].source == SourceID.daw0 + 1)
        #expect(doc.linkedPairs[8] && !doc.linkedPairs[0])
        #expect(doc.stereoMixPairs[0] && !doc.stereoMixPairs[1])
        #expect(doc.monitor.hardwareControl && doc.monitor.pad)
        #expect(doc.monitor.levelDB == -12)
        #expect(doc.monitor.modes[0] == .controlled && doc.monitor.modes[2] == .fixed)
        #expect(doc.mixes[0].name == "Band")
        let kick = doc.mixes[0].channels[0]
        #expect(kick.solo && kick.pan == -0.5 && abs(kick.gainDB! - 6) < 0.01)
        let daw = doc.mixes[0].channels[16]
        #expect(daw.mute && daw.pan == 0.5)                 // linked → balance
    }

    @Test func rejectsOtherXML() {
        #expect(throws: LegacySnapshot.ImportError.self) {
            try LegacySnapshot.load(Data("<foo/>".utf8))
        }
    }
}
