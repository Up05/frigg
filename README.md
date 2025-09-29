# Frigg

Frigg is a kind of memory viewer software-in-a-library for the Odin programming language.

Give the library a value; it will open a window. 
Use the arrow keys to browse the associated memory values.

Frigg works best on X11 Linux, because there are bugs with GLFW and wayland(or at least sway).  
Frigg also works on Windows, although it's less polished and (as far as I know) can crash by viewing bogus pointers.  
I am too poor to be able to test my software on MacOS. FreeBSD and the like: idk ¯\\\_(ツ)\_/¯.  
Frigg does not currently work on systems with OpenGL drivers.  

SOA pointers aren't really suported, they're not hard to implement, I just... kind of... couldn't be bothered...

Running the demo:  
<img width="1920" height="1020" alt="image" src="https://github.com/user-attachments/assets/f9b5d0d8-9161-4c26-8985-93a202df820d" />



# Usage

Download frigg and add it as a library in your project:
```sh
cd your_project
git clone https://github.com/Up05/frigg
```

Watch a variable and pause your program:
```odin
import "frigg"

main :: proc() {
    almost_anything: ??? 
    frigg.watch(almost_anything, pause_program = true)
}
```

Or watch a variable and keep on keeping on:
```odin
import "frigg"

main :: proc() {
    almost_anything: ??? // except soa pointers

    frigg.watch(almost_anything, pause_program = false)

    for {
        // update almost_anything...

        if !frigg.render_frame_for_all() do break
    }

}
```

*There are also other functions for setting multi-pointer length, ignoring stuff and, I guess, formatting values*

# Keyboard Shortcuts

`S` is `Shift`, `C` is `Ctrl`

Arrow keys can be used as alternative keybindings.

```
S Tab       ↑  go to line above
Tab         ↓  go to line below
C Enter   C →  go to value & make window
Enter       →  go to value
Backspace   ←  go back          
```

# Small value format

Printing of small values is designed to be obvious and short, but
there are some weirder cases:
```
..          skipping elements
..<LEN      skipping and here is the entire length
[:NUM]      the array is sliced via frigg.link(array, &new_max_length)
[0*LEN]     the array is filled with zeroes (surprisingly common)
(TYPE)      union's active variant
<self>      a pointer to a pointer to a... 16+ times over
```

