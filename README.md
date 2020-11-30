This is the actual Intcode compiler used during puzzle creation for [Advent of Code 2019](https://adventofcode.com/2019/) as specified by days [2](https://adventofcode.com/2019/day/2), [5](https://adventofcode.com/2019/day/5), and [9](https://adventofcode.com/2019/day/9).

It is not meant to provide a general-purpose assembly language, and many features are tedious or overzealous for actual use as an assembly language. Its design constraints are based on the use cases and overabundance of caution required when hand-crafting bytecode for puzzle inputs. In particular, it requires many obvious or auto-detectable things to be defined explicitly anyway, it prioritizes control over the output over comfort, its warnings are overly sensitive, and so on.

Some sample programs, including assembly versions of fresh inputs for various Advent of Code 2019 puzzles, can be found in the `samples` directory. Hopefully, some combination of the samples and my crude notes below will provide enough information to get started. Note that the puzzle inputs are intentionally not the best, cleanest way to achieve the apparent goal of the program; for example, various obfuscation techniques are employed throughout the puzzles to try to make solving the puzzle the intended way faster than solving it with reverse-engineering.

```
== invocation ==
./compile.pl [--trace] [--labels] <file>
  - '--trace' dumps assembly to stderr, including macro expansions
  - '--labels' dumps addresses of labels

== instructions ==
names: hlt add mul in out jt jf lt eq rbo
params:
  - '123' is immediate mode
  - '*123' is position mode
  - '~123' is relative mode
  - 'label' is position mode
  - '&label' is immediate mode

== macros ==
@fn <retvals> <fnname>([<arg>,...]) [local(<local>,...)] [global(<global>,...)]
  - declares a function
  - retvals is number of values to return
  - local(...) is local variables
  - global(...) is allowed labels from global scope
@endfn
  - ends a function declaration
@call <addr>
  - invokes a function
@cpy <src> <dst>
  - copies values by randomly generating 'add 0' and 'mul 1' instructions
@jmp <addr>
  - jumps unconditionally by randomly generating 'jt 1' and 'jf 0' instructions
@str [<label>:]"...."
  - converts a string into @raw syntax
@raw <val> ...
  - injects values directly into the program at this point

== other notes ==
- label 'auto__end' points to the end of the compiled data; useful for 'rbo &auto__end' to set up stack
```
