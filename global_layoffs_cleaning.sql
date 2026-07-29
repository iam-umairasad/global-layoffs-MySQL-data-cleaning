/*
============================================================
DATA CLEANING SCRIPT FOR 'LAYOFFS' TABLE
Purpose: Clean and prepare dataset for portfolio analysis
============================================================
*/

-- ========================================================= 
-- STEP 0: Setup 
-- Create a fresh working environment to ensure reproducibility 
-- =========================================================

DROP DATABASE IF EXISTS `global_layoffs`;
CREATE database `global_layoffs`;
USE `global_layoffs`;

-- Copy raw data from another database world_layoffs for cleaning:
CREATE TABLE layoffs AS
SELECT * FROM world_layoffs.layoffs;

-- Quick check: Confirm data imported successfully:
SELECT * FROM layoffs;

/*
Important steps in data cleaning:
-- 1. Remove duplicates
-- 2. Standardize the data
-- 3. Check for null or blank values
-- 4. Remove unnecessary rows or columns
============================================================
*/

-- =========================================================
-- STEP 1: Remove duplicates
-- Goal: Ensure each record is unique across all attributes by removing exact duplicate rows
-- Approach: Use ROW_NUMBER() with PARTITION BY on all columns
-- Result: Only one copy of each identical row remains in the dataset
-- =========================================================

-- Create a staging table to preserve raw data. This ensures we always have a backup in case of errors. 
CREATE TABLE layoff_staging AS
SELECT * FROM layoffs;

-- Initial duplicate check:
-- Partitioning by a subset of columns but not all columns
-- This helps us idenfify potential duplicates but may flag legitimate entries.

SELECT *,
       ROW_NUMBER() OVER (
           PARTITION BY company, industry, total_laid_off, percentage_laid_off, `date`
       ) AS row_num
FROM
    layoffs_staging;

WITH duplicate_cte AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY company, industry, total_laid_off, percentage_laid_off, `date`
           ) AS row_num
    FROM
        layoffs_staging
)
SELECT *
FROM
    duplicate_cte
WHERE
    row_num > 1;

-- Validation Step:
-- Manually inspect specific companies to confirm whether flagged rows
-- are true duplicates or legitimate entries.

SELECT * FROM layoffs_staging
WHERE company = 'Oda'; # Looks like a legitimate entry and shouldn't be deleted.

SELECT * FROM layoffs_staging
WHERE company = 'Casper'; # This is a duplicate

SELECT * FROM layoffs_staging
WHERE company = 'Cazoo'; # This is a duplicate.

SELECT * FROM layoffs_staging
WHERE company = 'Hibob'; # This is a duplicate.

SELECT * FROM layoffs_staging
WHERE company = 'Terminus'; # Looks like a legitimate entry and shouldn't be deleted.

SELECT * FROM layoffs_staging
WHERE company = 'Wildlife Studios'; # This is a duplicate.

SELECT * FROM layoffs_staging
WHERE company = 'Yahoo'; # This is a duplicate. 


-- Insight:
-- Partitioning by only a subset of columns risks deleting valid records
-- To avoid accidential data loss, We must partition by all columns.

-- Comprehensive Duplicate Check:
-- Partition by all columns and attributes to ensure only exact duplicates are flagged. 

-- these are our real duplicates 
SELECT *
FROM (
	SELECT company, location, industry, total_laid_off,
    percentage_laid_off,`date`, stage, country, funds_raised_millions,
		ROW_NUMBER() OVER (
			PARTITION BY company, location, industry, total_laid_off,
            percentage_laid_off,`date`, stage, country, funds_raised_millions
			) AS row_num
	FROM 
		layoffs_staging
) AS duplicates
WHERE 
	row_num > 1;

-- these are the ones we want to delete where the row number is > 1 

-- now if we want to write it like this this doesn't work because of MySQL Version limitation:
WITH DELETE_CTE AS 
(
SELECT *
FROM (
	SELECT company, location, industry, total_laid_off,percentage_laid_off,
    `date`, stage, country, funds_raised_millions,
		ROW_NUMBER() OVER (
			PARTITION BY company, location, industry, total_laid_off,percentage_laid_off,
            `date`, stage, country, funds_raised_millions
			) AS row_num
	FROM 
		layoffs_staging
) AS duplicates
WHERE 
	row_num > 1
)
DELETE
FROM DELETE_CTE
; 

-- MySQL 8.0 limitation:
-- UPDATE/DELETE operations are not allowed directly on CTEs.


WITH DELETE_CTE AS (
	SELECT company, location, industry, total_laid_off, percentage_laid_off, 
    `date`, stage, country, funds_raised_millions, 
    ROW_NUMBER() OVER (PARTITION BY company, location, industry, total_laid_off, percentage_laid_off, 
    `date`, stage, country, funds_raised_millions) AS row_num
	FROM layoffs_staging
)
DELETE FROM layoffs_staging
WHERE (company, location, industry, total_laid_off, percentage_laid_off, 
`date`, stage, country, funds_raised_millions, row_num) IN (
	SELECT company, location, industry, total_laid_off, percentage_laid_off, 
    `date`, stage, country, funds_raised_millions, row_num
	FROM DELETE_CTE
) AND row_num > 1;

-- MySQL 8.0 limitation:
-- UPDATE/DELETE operations are not allowed directly on CTEs.
-- Additionally, columns created inside a CTE (e.g., row_num from ROW_NUMBER())
-- do not exist in the base table and cannot be referenced in the DELETE clause.

-- one solution, which is looking good one is to create a new table and add a new column into it and add 
-- those row numbers in that column. Then delete rows where row_num > 2, then delete that column
-- so let's do it!!

CREATE TABLE layoff_staging2 AS
SELECT
    *,
    ROW_NUMBER() OVER (
        PARTITION BY company, location, industry, total_laid_off,
                     percentage_laid_off, `date`, stage, country,
                     funds_raised_millions
    ) AS row_num
FROM layoffs_staging;

-- now that we have this we can delete rows were row_num > 1:

# Delete all rows where row_num > 1 (Duplicates)
DELETE FROM layoff_staging2    
WHERE row_num > 1;

-- Temporarily disable safe updates to allow deletion:
SET SQL_SAFE_UPDATES = 0;

-- Final check: Confirm cleaned dataset after deletion:
SELECT * FROM layoff_staging2;

-- Re-enable safe updates for best practice.
SET SQL_SAFE_UPDATES = 1;

-- ================================================================================================ --

-- =========================================================
-- STEP 2: Standardize the data
-- Goal: Ensure consistency across categorical and formatted fields 
--       (e.g., industry, country names, and date values)
-- Approach: Normalize text values (trim spaces, unify variations), 
--           replace blanks with NULLs, update missing values using 
--           related records, and convert date strings to proper DATE type
-- Result: Clean, consistent fields that improve accuracy in analysis 
--         and prevent misclassification during reporting
-- =========================================================


USE `global_layoffs`;
SELECT * 
FROM layoff_staging2;

-- Checking the industry column, some rows appear to be blank or NULL. Let's review them.
SELECT DISTINCT industry
FROM layoff_staging2
ORDER BY industry;

SELECT *
FROM global_layoffs.layoff_staging2
WHERE industry IS NULL 
OR industry = ''
ORDER BY industry;

-- let's review these
SELECT *
FROM global_layoffs.layoff_staging2
WHERE company LIKE 'Bally%';
-- No issues found here

-- Let's look at airbnb:
SELECT *
FROM global_layoffs.layoff_staging2
WHERE company LIKE 'airbnb%';

-- Airbnb is part of travel, yet the industry column has not been populated here.
-- Likely, other companies face the same issue. Our approach will be:
-- Use matching company names to fill NULL industries with existing valid entries.
-- This method scales efficiently, avoiding manual checks even if thousands of rows exist.


-- Replace blank industry values with NULL for easier handling
UPDATE global_layoffs.layoff_staging2
SET industry = NULL
WHERE industry = '';

-- Verifying now shows all values as NULL
SELECT *
FROM global_layoffs.layoff_staging2
WHERE industry IS NULL 
OR industry = ''
ORDER BY industry;

-- Next step: We should populate missing industry entries using available data

UPDATE layoff_staging2 t1
JOIN layoff_staging2 t2
ON t1.company = t2.company
SET t1.industry = t2.industry
WHERE t1.industry IS NULL
AND t2.industry IS NOT NULL;

-- After checking, Bally's appears to be the only company without a populated industry value
SELECT *
FROM global_layoffs.layoff_staging2
WHERE industry IS NULL 
OR industry = ''
ORDER BY industry;

-- ---------------------------------------------------

-- I also noticed the Crypto has multiple different variations. like "CryptoCurrency" and "Crypto Currency";
-- Standardize these variations by converting them all to 'Crypto'

SELECT DISTINCT industry
FROM global_layoffs.layoff_staging2
ORDER BY industry;

UPDATE layoff_staging2
SET industry = 'Crypto'
WHERE industry IN ('Crypto Currency', 'CryptoCurrency');

-- The standardization step is complete
SELECT DISTINCT industry
FROM Global_layoffs.layoff_staging2
ORDER BY industry;

-- --------------------------------------------------
-- Next, let’s examine another aspect of the dataset

SELECT *
FROM global_layoffs.layoff_staging2;

-- The only issue is inconsistent country names: 'United States' vs. 'United States.' . 
-- There are entries with the period at the end in the country names. We need to normalize them.
SELECT DISTINCT country
FROM global_layoffs.layoff_staging2
ORDER BY country;

UPDATE layoff_staging2
SET country = TRIM(TRAILING '.' FROM country);

-- now if we run this again it is fixed
SELECT DISTINCT country
FROM global_layoffs.layoff_staging2
ORDER BY country;


-- Let's also fix the date columns:
SELECT *
FROM global_layoffs.layoff_staging2;

-- we can use str to date to update this field
UPDATE layoff_staging2
SET `date` = STR_TO_DATE(`date`, '%m/%d/%Y');

-- now we can convert the data type properly
ALTER TABLE layoff_staging2
MODIFY COLUMN `date` DATE;


SELECT *
FROM global_layoff.layoff_staging2;


-- ============================================================================================== --
-- ============================================================================================== --

# Step#3 : Look at null values:

-- Nulls in total_laid_off, percentage_laid_off, and funds_raised_millions appear valid, so no changes needed
-- Keeping NULLs helps simplify calculations during exploratory data analysis

-- Therefore, no adjustments are required for the NULL values

-- ============================================================================================== --


-- ================================================== --
-- Step#4: remove any columns and rows we need to
-- ================================================== --

Use `global_layoffs`;

SELECT *
FROM global_layoffs.layoff_staging2
WHERE total_laid_off IS NULL;


SELECT *
FROM global_layoffs.layoff_staging2
WHERE total_laid_off IS NULL
AND percentage_laid_off IS NULL;

-- Delete Useless data we can't really use 
DELETE FROM global_layoffs.layoff_staging2
WHERE total_laid_off IS NULL
AND percentage_laid_off IS NULL;

SELECT * 
FROM global_layoffs.layoff_staging2;

ALTER TABLE layoff_staging2
DROP COLUMN row_num;

SELECT * 
FROM global_layoffs.layoff_staging2;








