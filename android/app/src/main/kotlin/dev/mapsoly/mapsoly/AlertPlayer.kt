package dev.mapsoly.mapsoly

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack

/**
 * Plays a short 16-bit mono PCM clip (the speeding signal the Dart side
 * generates) as navigation guidance audio: over music, at the media volume.
 */
class AlertPlayer {
    private var track: AudioTrack? = null

    fun play(pcm: ByteArray, rate: Int): Boolean = try {
        release()
        val t = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            pcm.size,
            AudioTrack.MODE_STATIC,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        // The whole clip is loaded first; play() then returns at once.
        t.write(pcm, 0, pcm.size)
        t.play()
        track = t
        true
    } catch (e: Exception) {
        android.util.Log.w("mapsoly", "alert sound failed: $e")
        false
    }

    fun release() {
        try {
            track?.release()
        } catch (e: Exception) {
            // Already gone.
        }
        track = null
    }
}
