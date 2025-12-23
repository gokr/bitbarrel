## BitBarrel Reference Model - Organization Chart Demo
##
## This example demonstrates hierarchical data navigation using
## the reference model for org charts and reporting structures.

import std/[json, strformat, strutils]
import network/client
from std/net import Port
import bitbarrel/refs

proc main() =
  echo "=== BitBarrel Organization Chart Demo ==="
  echo()

  # Setup
  var client = newClient("localhost", Port(9876))
  if not client.createBarrel("org"):
    discard client.openBarrel("org")
  discard client.useBarrel("org")

  echo "✓ Connected to BitBarrel server"
  echo()

  # Create org structure
  echo "Building organization hierarchy..."

  let ceoData = %*{
    "name": "John Smith",
    "title": "CEO",
    "department": "Executive",
    "_refs": {
      "direct_reports": ["emp:cto", "emp:cfo", "emp:vp_sales"]
    }
  }
  discard client.set("emp:ceo", $ceoData)

  let ctoData = %*{
    "name": "Sarah Johnson",
    "title": "Chief Technology Officer",
    "department": "Engineering",
    "_refs": {
      "direct_reports": ["emp:eng_mgr1", "emp:eng_mgr2"],
      "manager": ["emp:ceo"]
    }
  }
  discard client.set("emp:cto", $ctoData)

  let cfoData = %*{
    "name": "Michael Brown",
    "title": "Chief Financial Officer",
    "department": "Finance",
    "_refs": {
      "direct_reports": ["emp:finance_mgr"],
      "manager": ["emp:ceo"]
    }
  }
  discard client.set("emp:cfo", $cfoData)

  let vpSalesData = %*{
    "name": "Emily Davis",
    "title": "VP of Sales",
    "department": "Sales",
    "_refs": {
      "direct_reports": ["emp:sales_mgr1", "emp:sales_mgr2"],
      "manager": ["emp:ceo"]
    }
  }
  discard client.set("emp:vp_sales", $vpSalesData)

  let engMgr1Data = %*{
    "name": "David Wilson",
    "title": "Engineering Manager",
    "department": "Engineering",
    "_refs": {
      "direct_reports": ["emp:senior_dev1", "emp:senior_dev2"],
      "manager": ["emp:cto"]
    }
  }
  discard client.set("emp:eng_mgr1", $engMgr1Data)

  let seniorDev1Data = %*{
    "name": "Lisa Anderson",
    "title": "Senior Developer",
    "department": "Engineering",
    "_refs": {
      "manager": ["emp:eng_mgr1"]
    }
  }
  discard client.set("emp:senior_dev1", $seniorDev1Data)

  echo "✓ Created 6-person org hierarchy"
  echo()

  # Demo 1: CEO's direct reports
  echo "Demo 1: CEO's direct reports"
  echo "Path: direct_reports"
  let ceoReports = client.traversePath("emp:ceo", "direct_reports")
  for r in ceoReports:
    let emp = parseJson(r.value)
    echo fmt("  - {emp[\"title\"].getStr()}: {emp[\"name\"].getStr()}")
  echo()

  # Demo 2: Full reporting tree under CEO
  echo "Demo 2: Complete reporting tree (all levels)"
  echo "Path: direct_reports->direct_reports->direct_reports"
  let allReports = client.traversePath("emp:ceo",
    "direct_reports->direct_reports->direct_reports")

  var indent = "  "
  for r in allReports:
    let level = r.path.count("direct_reports")
    let emp = parseJson(r.value)
    echo fmt("{indent.repeat(level)}- {emp[\"title\"].getStr()}: {emp[\"name\"].getStr()}")
  echo()

  # Demo 3: Find all Engineering department members
  echo "Demo 3: All Engineering department members"
  # First get all employees, then filter by department
  let allEmps = client.traversePath("emp:ceo", "*")
  var engineers: seq[string] = @[]
  for e in allEmps:
    let emp = parseJson(e.value)
    if emp["department"].getStr() == "Engineering":
      engineers.add(fmt("{emp[\"title\"].getStr()}: {emp[\"name\"].getStr()}"))

  for eng in engineers:
    echo fmt("  - {eng}")
  echo()

  # Demo 4: Management chain for a senior developer
  echo "Demo 4: Management chain for Senior Developer"
  echo "Path: manager->manager (following upwards)"

  # We need to follow manager refs up the chain
  var current = "emp:senior_dev1"
  var chain: seq[string] = @[]

  # Manual traversal since we're going upward
  for i in 0..2:
    let emp = parseJson(client.get(current))
    let name = emp["name"].getStr()
    let title = emp["title"].getStr()
    chain.add(fmt("{title}: {name}"))

    # Get manager if exists
    let refs = extractRefs(client.get(current))
    if refs.hasKey("manager") and refs["manager"].len > 0:
      current = refs["manager"][0]
    else:
      break

  echo "  Management chain (top to bottom):"
  for i in countdown(chain.len - 1, 0):
    let prefix = if i == 0: "  └─" else: "  │"
    echo fmt("{prefix} {chain[i]}")
  echo()

  # Demo 5: Find common manager
  echo "Demo 5: Finding common leadership"
  echo "CTO and CFO both report to:"

  let ctoMgr = client.traversePath("emp:cto", "manager")
  let cfoMgr = client.traversePath("emp:cfo", "manager")

  for cm in ctoMgr:
    for fm in cfoMgr:
      if cm.key == fm.key:
        let ceo = parseJson(cm.value)
        echo fmt("  - {ceo[\"title\"].getStr()}: {ceo[\"name\"].getStr()}")
  echo()

  # Demo 6: Department size analysis
  echo "Demo 6: Department size analysis"
  var deptCounts: Table[string, int]

  # Count direct reports by department
  let managers = client.traversePath("emp:ceo", "direct_reports")
  for m in managers:
    let emp = parseJson(m.value)
    let dept = emp["department"].getStr()

    # Count this manager's direct reports
    let refs = extractRefs(m.value)
    if refs.hasKey("direct_reports"):
      deptCounts[dept] = refs["direct_reports"].len

  for dept, count in deptCounts:
    echo fmt("  - {dept}: {count} direct reports")
  echo()

  # Demo 7: Skip-level connections
  echo "Demo 7: Skip-level reporting (who reports to my reports?)"
  echo "Path: direct_reports->direct_reports"
  let skipLevel = client.traversePath("emp:ceo",
    "direct_reports->direct_reports")

  for r in skipLevel:
    let emp = parseJson(r.value)
    let parts = r.path.split("->")
    let managerKey = parts[1]  # Get the manager in the path
    let manager = parseJson(client.get(managerKey))
    echo fmt("  - {emp[\"name\"].getStr()} ({emp[\"title\"].getStr()})")
    echo fmt("    reports to: {manager[\"name\"].getStr()}")
  echo()

  echo "=== Org Chart Demo Complete ==="
  echo()
  echo "Key concepts demonstrated:"
  echo "✓ Hierarchical navigation (up and down)"
  echo "✓ Multi-level traversals (direct_reports->direct_reports)"
  echo "✓ Cross-department analysis"
  echo "✓ Management chain discovery"
  echo "✓ Skip-level reporting relationships"
  echo "✓ Department size and structure analysis"

when isMainModule:
  main()
