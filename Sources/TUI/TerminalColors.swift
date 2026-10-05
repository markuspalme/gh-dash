import Darwin.ncurses
import Foundation
import TermKit

/// Makes the app blend into the terminal's own colour scheme.
///
/// TermKit only knows the 16 ANSI colours, so "black on white" means the
/// theme's ANSI black and white, not the terminal's actual background and
/// text colours. Once every attribute the app uses exists, this rewrites the
/// curses colour pairs so that a black background and a white foreground
/// become the terminal's defaults instead.
enum TerminalColors {
    @MainActor
    static func adoptTerminalDefaults() {
        // Only the curses driver has colour pairs to rewrite.
        guard String(describing: type(of: Application.driver)) == "CursesDriver" else { return }
        // Create every attribute the dashboard will ask for, so their pairs exist now.
        for style in Style.allCases {
            _ = style.attribute(selected: false)
            _ = style.attribute(selected: true)
        }
        guard use_default_colors() == OK else { return }
        for pair in Int16(1)...Int16(255) {
            var fore: Int16 = 0
            var back: Int16 = 0
            guard pair_content(pair, &fore, &back) == OK else { continue }
            let newFore = fore == Int16(COLOR_WHITE) ? Int16(-1) : fore
            let newBack = back == Int16(COLOR_BLACK) ? Int16(-1) : back
            if newFore != fore || newBack != back {
                init_pair(pair, newFore, newBack)
            }
        }
    }
}
