// Package tools imports things required by build scripts, to force `go mod` to see them as dependencies
package tools

import (
	_ "k8s.io/kube-openapi/cmd/openapi-gen"
)
