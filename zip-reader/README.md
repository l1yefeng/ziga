# zip-reader

- `zip.zig` implements a zip file reader.
- `main.zig` is an example of using it. It prints contents of all files in the given zip file.

This implementation tries to successfully read a zip file when all of the following are true:

1. It is a proper zip file.
1. Not using Zip64 extension.
1. Not using the encryption feature.
1. Not using the multiple-volume feature.
