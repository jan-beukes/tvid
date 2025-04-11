package tvid

import "base:runtime"
import "core:fmt"
import "core:time"
import "core:sys/posix"
import "core:io"
import os "core:os/os2"

Video_Output :: struct {
    stdout: ^os.File,
    fps: f64,
}

Pixel :: [3]u8

RESX :: 80
RESY :: 50
NB_COMPS :: 3
ESC :: "\x1b["
BYTES_PER_FRAME :: RESX * RESY * NB_COMPS

@(rodata)
ascii_table := ".,wW#"

launch_ffmpeg :: proc(video_file: string) -> Video_Output {

    buf: [128]u8
    res := fmt.bprintf(buf[:], "%dx%d", RESX, RESY)
    argv := []string {
        "ffmpeg", "-i", video_file, "-f", "rawvideo", 
        "-pix_fmt", "rgb24",  "-s", res, "-an", "-",
    }

    pipe_r, pipe_w, _ := os.pipe()
    desc := os.Process_Desc {
        command = argv,
        stdout = pipe_w,
    }

    p, err := os.process_start(desc)
    if err != nil {
        os.exit(1)
    }

    return Video_Output {pipe_r, 23.98}
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

    fmt.print(ESC + "H", flush = false);
    for y in 0..<RESY {
        for x in 0..<RESX {
            pixel := pixels[y * RESX + x]
            luminance := pixel_luminance(pixel)
            idx := int(luminance * f32(len(ascii_table) - 1))
            char := ascii_table[idx]
            fmt.printf(ESC + "38;2;%d;%d;%dm" + "%c%c", pixel.r, pixel.g, pixel.b, char, char, flush = false)
        }
        fmt.print("\n", flush = false)
    }
    os.flush(os.stdout)
}

main :: proc() {

    video_file := "puss.webm"

    video := launch_ffmpeg(video_file)
    frame_time := time.Duration((1.0 / video.fps) * f64(time.Second))

    buf: [BYTES_PER_FRAME]u8
    prev_frame_time := time.now()
    posix.signal(.SIGINT, show_cursor_and_exit)
    fmt.print(ESC + "?25l")
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
    fmt.print(ESC + "?25h")
}

show_cursor_and_exit:: proc "c" (sig: posix.Signal) {
    context = runtime.default_context()
    fmt.print(ESC + "?25h")
    os.exit(0)
}
