# Task: Organize Content with Collections

## Archetype
Setup / Configuration

## Prompt
Organize the existing Metabase content using collections:

1. Create a new collection called "Executive Dashboards" at the root level
   (inside "Our analytics").
2. Move the existing "Sales Overview" dashboard into the "Executive
   Dashboards" collection.
3. Create a sub-collection inside "Executive Dashboards" called "Archive".
4. Navigate back to "Executive Dashboards" and verify it contains the
   "Sales Overview" dashboard and the "Archive" sub-collection.

## Expected Result
- A collection named "Executive Dashboards" exists at the root level
  (inside "Our analytics")
- The "Sales Overview" dashboard has been moved into "Executive Dashboards"
- A sub-collection named "Archive" exists inside "Executive Dashboards"
- Navigating to "Executive Dashboards" shows both the "Sales Overview"
  dashboard and the "Archive" sub-collection
- The "Sales Overview" dashboard no longer appears in its original location
  ("Our analytics" root)

## Seed Data Required
- Metabase is set up with admin user (admin@example.com / Admin123!)
- "Sales Overview" dashboard exists (created by the seed script)
- "Team Reports" collection exists (created by the seed script — not
  modified by this task)
