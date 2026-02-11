# Task: Write and Save a SQL Query

## Archetype
Routine Execution

## Prompt
Open the native SQL editor by clicking "New" > "SQL query". Select the
Sample Database as the data source. Write a SQL query that finds the top 5
products by total revenue (the sum of order totals for each product). The
query should:
- Join ORDERS and PRODUCTS tables on the product ID
- Return two columns: the product title/name and the total revenue
- Order results from highest revenue to lowest
- Limit to 5 rows

Run the query to verify it returns results. Then save it as
"Top Products by Revenue" in the default "Our analytics" collection.

## Expected Result
- A saved question named "Top Products by Revenue" exists in "Our analytics"
- The question uses native SQL (not the visual query builder)
- Running the question returns exactly 5 rows
- Each row shows a product name/title and a revenue total
- Rows are ordered by revenue from highest to lowest
- The question is associated with the Sample Database

## Seed Data Required
- Metabase is set up with admin user (admin@example.com / Admin123!)
- Sample Database is connected and synced (includes ORDERS and PRODUCTS tables)
