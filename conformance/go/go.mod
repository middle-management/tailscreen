module github.com/middle-management/tailscreen/conformance

go 1.21

require github.com/middle-management/tailscreen/sdk/go v0.0.0

// The SDK lives in this repository and is versioned with it, so the runner
// builds against the working tree rather than a published tag — a vector and
// the implementation it pins must never be one module release apart.
replace github.com/middle-management/tailscreen/sdk/go => ../../sdk/go
