[![progress-banner](https://backend.codecrafters.io/progress/grep/79f62e45-ebd5-467b-99fb-af2b65fa8b37)](https://app.codecrafters.io/users/quangd42)

This is my Zig solutions to the
["Build Your Own grep" Challenge](https://app.codecrafters.io/courses/grep/overview).

[Regular expressions](https://en.wikipedia.org/wiki/Regular_expression)
(Regexes, for short) are patterns used to match character combinations in
strings. [`grep`](https://en.wikipedia.org/wiki/Grep) is a CLI tool for
searching using Regexes.

In this challenge I built your own implementation of `grep`. I learned more about Regex syntax,
and how regular expressions are evaluated.

To try it out:

1. Ensure you have `zig (0.14)` installed locally
1. Run `./grep.sh` instead of `grep`. For example,

```sh
./grep.sh -E "b.+" test/data/fruits.txt test/data/vegetables.txt

./grep.sh -r -E "b.+" test/
```
