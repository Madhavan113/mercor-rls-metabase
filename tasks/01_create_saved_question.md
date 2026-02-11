# Task: Create a Saved Question

## Archetype
Routine Execution

## Prompt
Create a new question using the Sample Database and the visual query builder
(not SQL). Configure the question to show the average order total grouped by
Product Category. To do this:
1. Click "New" > "Question"
2. Select the Sample Database
3. Pick the "Orders" table
4. Add a summarization: Average of "Total"
5. Group by Product > "Category"
6. Visualize the result as a bar chart
7. Save the question as "Average Order Value by Category" in the default
   "Our analytics" collection

## Expected Result
- A saved question named "Average Order Value by Category" appears in
  "Our analytics"
- The visualization is a bar chart
- The chart shows one bar per product category with the average order total
- The question uses the Sample Database and the visual query builder
  (not native SQL)

## Seed Data Required
- Metabase is set up with admin user (admin@example.com / Admin123!)
- Sample Database is connected and synced (includes ORDERS and PRODUCTS tables)
