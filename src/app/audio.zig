const r = @import("raylib");

pub const Cue = enum { select, build, denied, trade, sail, beacon, anchor_drop, foghorn };
const cues = @typeInfo(Cue).@"enum".field_names;

pub const Effects = struct {
    sounds: [cues.len]?r.Sound = @splat(null),

    pub fn init() Effects {
        var effects = Effects{};
        r.initAudioDevice();
        if (r.isAudioDeviceReady()) {
            inline for (cues, 0..) |cue, i| load: {
                const wave = r.loadWaveFromMemory(".wav", @embedFile("sfx/" ++ cue ++ ".wav")) catch break :load;
                defer r.unloadWave(wave);
                const sound = r.loadSoundFromWave(wave);
                if (r.isSoundValid(sound)) effects.sounds[i] = sound;
            }
        }
        return effects;
    }

    pub fn play(self: *const Effects, cue: Cue) bool {
        const sound = self.sounds[@backingInt(cue)] orelse return false;
        r.playSound(sound);
        return true;
    }

    pub fn deinit(self: *const Effects) void {
        for (self.sounds) |slot| {
            if (slot) |sound| r.unloadSound(sound);
        }
        if (r.isAudioDeviceReady()) r.closeAudioDevice();
    }
};
