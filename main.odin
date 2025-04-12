package tvid

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:sys/windows"
import "core:strings"
import "core:strconv"
import "core:time"

import "core:c/libc"
import "core:io"
import os "core:os/os2"

MAX_ROWS :: 160
RESX :: 60
RESY :: 34
NB_COMPS :: 3

// ANSI escape codes
ESC :: "\e["

ANSI_HIDE_CURSOR :: ESC + "?25l"
ANSI_SHOW_CURSOR :: ESC + "?25h"
ANSI_CLEAR_SCREEN :: ESC + "2J"

@(rodata)
ascii_table := ".,:;lxokdXO0KN#"

Video_Output :: struct {
    process: os.Process,
    stdout: ^os.File,
    fps: f64,
    resx, resy: u32,
}

Pixel :: [3]u8

// this is honestly pretty sketch since mac doesn't have ioctl defined we define it here
get_term_size :: proc() -> (rows: u16, cols: u16) {

    when ODIN_OS == .Windows {
        std_handle := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
        csbi: windows.CONSOLE_SCREEN_BUFFER_INFO
        windows.GetConsoleScreenBufferInfo(std_handle, &csbi)

        rows, cols = u16(csbi.dwSize.Y), u16(csbi.dwSize.X)
        return
    } else {
        // from ioctls.h
        TIOCGWINSZ :: 0x5413

        // from ioctl-types.h
        Win_Size :: struct {
            rows, cols: u16,
            xpixel, ypixel: u16,
        }

        foreign {
            ioctl :: proc(fd: i32, request: u32, arg: uintptr) -> uintptr ---
        }

        size: Win_Size
        fd := os.fd(os.stdout)
        ioctl(auto_cast fd, TIOCGWINSZ, uintptr(&size))

        rows, cols = size.rows, size.cols
        return
    }
}

launch_ffmpeg :: proc(video_file: string, rows: u16) -> (output: Video_Output, ok: bool) {
    ok = true
    // ffprobe command to extract data from video file
    probe_cmd := []string {
        "ffprobe", "-v", "0", "-select_streams", "v:0", 
        "-show_entries", "stream=width,height,r_frame_rate", "-of", "csv=p=0",
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

    // parse probe data
    data_str := string(probe_out)
    tokens, _ := strings.split(data_str, ",")
    assert(len(tokens) >= 3)

    vidx, _ := strconv.parse_uint(tokens[0])
    vidy, _ := strconv.parse_uint(tokens[1])
    resy := u32(rows)
    resx := u32(uint(rows) * vidx / vidy)

    fps_str := tokens[2]
    sep := strings.index_byte(fps_str, '/')
    num, _ := strconv.parse_int(fps_str[:sep])
    den, _ := strconv.parse_int(fps_str[sep + 1:])
    fps := f64(num) / f64(den)

    // ffmpeg command to write raw rgb24 to stdout
    buf: [128]u8
    res := fmt.bprintf(buf[:], "%dx%d", resx, resy)
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

    output = Video_Output {
        process = p,
        stdout = pipe_r,
        fps = fps, 
        resx = resx,
        resy = resy,
    }

    return
}

pixel_luminance :: #force_inline proc(pixel: Pixel) -> f32 {
    r := f32(pixel.r) / 255.0
    g := f32(pixel.g) / 255.0
    b := f32(pixel.b) / 255.0

    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

print_frame :: proc(data: []u8, resx, resy: u32) {
    pixels_ptr := cast([^]Pixel)raw_data(data)
    pixels := pixels_ptr[:len(data) / NB_COMPS]

    // Using string builder seems to improve performance over fmt printing
    // even when buffering
    builder: strings.Builder
    strings.builder_init(&builder)
    defer strings.builder_destroy(&builder)

    fmt.print(ESC + "H");
    for y in 0..<resy {
        for x in 0..<resx {
            pixel := pixels[y * resx + x]
            luminance := pixel_luminance(pixel)
            idx := int(luminance * f32(len(ascii_table) - 1))
            char := ascii_table[idx]

            strings.write_string(&builder, ESC + "38;2;")
            strings.write_uint(&builder, uint(pixel.r))
            strings.write_byte(&builder, ';')
            strings.write_uint(&builder, uint(pixel.g))
            strings.write_byte(&builder, ';')
            strings.write_uint(&builder, uint(pixel.b))
            strings.write_string(&builder, ";m")
            strings.write_byte(&builder, char)
            strings.write_byte(&builder, char)
        }
        strings.write_byte(&builder, '\n')
    }
    os.write(os.stdout, builder.buf[:])
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

    // args
    args := os.args
    if len(args) < 2 {
        usage()
        os.exit(1)
    }
    video_file := args[len(args) - 1]

    // try to get term size using ioctl
    rows, _ := get_term_size()

    if rows == 0 {
        rows = RESY
    } else {
        // When the height of the video is larger than the number of rows 
        // the output is jittery so we just make output slightly smaller
        rows = min(rows - 2, MAX_ROWS)
    }

    video, ok := launch_ffmpeg(video_file, rows)
    if !ok {
        os.exit(1)
    }
    frame_time := time.Duration((1.0 / video.fps) * f64(time.Second))
    resx, resy := video.resx, video.resy

    // Hide the cursor and set up interup signal handler to show cursor before exit
    libc.signal(libc.SIGINT, reset_and_exit)
    fmt.print(ANSI_HIDE_CURSOR) // hide cursor
    fmt.print(ANSI_CLEAR_SCREEN)
    defer {
        fmt.print(ANSI_SHOW_CURSOR)
        fmt.print(ANSI_CLEAR_SCREEN)
    }

    bytes_per_frame := int(resx * resy) * NB_COMPS
    buf := make([]u8, bytes_per_frame)
    defer delete(buf)
    prev_frame_time := time.now()
    for {
        now := time.now()
        diff := time.diff(prev_frame_time, now)
        if diff > frame_time {
            prev_frame_time = time.now()
            n, err := os.read_at_least(video.stdout, buf[:], bytes_per_frame)
            if err != nil do break
            print_frame(buf[:n], resx, resy)

            // I think this is the only way to exit
            // since ffmpeg doesn't write EOF, os.read just blocks when ffmpeg is done
            state: os.Process_State
            state, err = os.process_wait(video.process, time.Microsecond)

            // process is done
            if err != os.General_Error.Timeout {
                break
            }
        }

    }
}

reset_and_exit:: proc "c" (sig: i32) {
    context = runtime.default_context()
    fmt.print(ANSI_CLEAR_SCREEN)
    fmt.print(ESC + "?25h")
    os.exit(0)
}
