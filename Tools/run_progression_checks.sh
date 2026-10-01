#!/bin/bash
# Run from any working directory. Does not rebuild or alter bundled car assets.
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/drive-ar-progression.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
core=(vr/Car/{CarCatalog,CarCatalogGenerated,CarPaint,VehicleTuning,Drivetrain,SimulationScale,DrivingInput,VehicleDynamics}.swift)
logic=(vr/Progression/{ProgressionCatalog,MissionCatalog,ProgressionStore,DrivingEvaluator,ProgressionModel,OverlayPlacement}.swift)
xcrun swiftc -parse-as-library -O -o "$check_dir/progression" "${core[@]}" "${logic[@]}" Tools/{MeasuredCarGeometry,ProgressionChecks,ProgressionEdgeChecks,EverydayTechniqueChecks}.swift
"$check_dir/progression" vr/Resources
xcrun swiftc -parse-as-library -O -o "$check_dir/audit" "${core[@]}" vr/Progression/{ProgressionCatalog,MissionCatalog,DrivingEvaluator}.swift Tools/{MeasuredCarGeometry,ProgressionDrivingAudit}.swift
"$check_dir/audit" vr/Resources
xcrun swiftc -parse-as-library -O -o "$check_dir/economy" "${core[@]}" vr/Progression/{ProgressionCatalog,MissionCatalog,ProgressionStore}.swift Tools/EconomySimulation.swift
"$check_dir/economy" > "$check_dir/EconomyReport.md"
cat "$check_dir/EconomyReport.md"
