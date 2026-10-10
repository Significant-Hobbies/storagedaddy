FinderSearch: https://github.com/zeusinsight/FinderSearch
Commit: 44eb8c30583270a93fb64146c8d2d1a2f296053b

The fsearch library is vendored unmodified from vendor/fsearch at this commit.
StorageDaddy uses its filename index and query engine over existing scan metadata.
The adapter does not start its whole-disk daemon, read file contents, persist an
index, or register a login agent. Swift transport is adapted from Engine.swift.
Both upstream MIT notices are retained.
