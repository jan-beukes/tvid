package tvid

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:c/libc"
import "core:io"
import os "core:os/os2"

Video_Output :: struct {
    stdout: ^os.File,
    fps: f64,
}

Pixel :: [3]u8

RESX :: 80
RESY :: 45
NB_COMPS :: 3
BYTES_PER_FRAME :: RESX * RESY * NB_COMPS

// ANSI escape codes
ESC :: "\e["
ANSI_RGB_FMT :: ESC + "38;2;%d;%d;%dm"

ANSI_HIDE_CURSOR :: ESC + "?25l"
ANSI_SHOW_CURSOR :: ESC + "?25h"
ANSI_CLEAR_SCREEN :: ESC + "2J"

@(rodata)
ascii_table := " .',:;xlxokXdO0KN"

launch_ffmpeg :: proc(video_file: string) -> (output: Video_Output, ok: bool) {
    ok = true

    // ffprobe command to extract data from video file
    probe_cmd := []string {
        "ffprobe", "-v", "0", "-select_streams", "v:0", 
        "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0",
        video_file,
    }

    // run ffprobe to make sure file is valid and to extract info
    p_state, probe_out, _, err := os.process_exec({ command = probe_cmd }, context.allocator)
    if err != nil {
        log.error("Could not execute ffprobe,", err)
        ok = false
        return
    } else if p_state.exit_code != 0 {
        log.error("Could not read video file,", video_file)
        ok = false
        return
    }

    fps_str := string(probe_out)
    sep := strings.index_byte(fps_str, '/')
    num, _ := strconv.parse_int(fps_str[:sep])
    den, _ := strconv.parse_int(fps_str[sep + 1:])
    fps := f64(num) / f64(den)


    // ffmpeg command to write raw rgb24 to stdout
    buf: [128]u8
    res := fmt.bprintf(buf[:], "%dx%d", RESX, RESY)
    cmd := []string {
        "ffmpeg", "-i", video_file, "-f", "rawvideo", 
        "-pix_fmt", "rgb24",  "-s", res, "-an", "-",
    }

    pipe_r, pipe_w, err_pipe := os.pipe()
    if err_pipe != nil {
        log.error("Could not create pipe")
        ok = false
        return
    }

    p, err_proc := os.process_start({
        command = cmd, 
        stdout = pipe_w,
    })

    if err_pipe != nil {
        log.error("Could not start ffmpeg process")
        ok = false
        return
    }

    output = {pipe_r, fps}

    return
}

pixel_luminance :: proc(pixel: Pixel) -> f32 {
    r := f32(pixel.r) / 255.0
    g := f32(pixel.g) / 255.0
    b := f32(pixel.b) / 255.0

    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

print_frame :: proc(data: []u8) {
    pixels_ptr := cast([^]Pixel)raw_data(data)
    pixels := pixels_ptr[:len(data) / NB_COMPS]

    fmt.print(ESC + "H");
    for y in 0..<RESY {
        for x in 0..<RESX {
            pixel := pixels[y * RESX + x]
            luminance := pixel_luminance(pixel)
            idx := int(luminance * f32(len(ascii_table) - 1))
            char := ascii_table[idx]
            fmt.printf(ANSI_RGB_FMT + "%c%c", pixel.r, pixel.g, pixel.b, char, char, flush = false)
        }
        fmt.print("\n", flush = false)
    }
    os.flush(os.stdout)
}

usage :: proc() {
    fmt.println(
`
Usage: tvid <file>
`
    )

}

main :: proc() {
    context.logger = log.create_console_logger(opt = log.Options{.Level, .Terminal_Color})

    args := os.args
    if len(args) < 2 {
        usage()
        os.exit(1)
    }
    video_file := args[len(args) - 1]

    video, ok := launch_ffmpeg(video_file)
    if !ok {
        os.exit(1)
    }
    frame_time := time.Duration((1.0 / video.fps) * f64(time.Second))

    // Hide the cursor and set up interup signal handler to show cursor before exit
    libc.signal(libc.SIGINT, reset_and_exit)
    fmt.print(ANSI_HIDE_CURSOR) // hide cursor
    fmt.print(ANSI_CLEAR_SCREEN)
    defer {
        fmt.print(ANSI_SHOW_CURSOR)
        fmt.print(ANSI_CLEAR_SCREEN)
    }

    buf: [BYTES_PER_FRAME]u8
    prev_frame_time := time.now()
    for {
        now := time.now()
        diff := time.diff(prev_frame_time, now)
        if diff > frame_time {
            prev_frame_time = time.now()
            n, err := os.read_at_least(video.stdout, buf[:], BYTES_PER_FRAME)
            if err != nil do break
            print_frame(buf[:n])
        }

    }
}

reset_and_exit:: proc "c" (sig: i32) {
    context = runtime.default_context()
    fmt.print(ANSI_CLEAR_SCREEN)
    fmt.print(ESC + "?25h")
    os.exit(0)
}
