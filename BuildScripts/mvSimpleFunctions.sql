/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mvSimpleFunctions.sql
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Background:     PostGre does not support Materialized View Fast Refreshes, this suite of scripts is a PL/SQL coded mechanism to
                provide that functionality, the next phase of this projecdt is to fold these changes into the PostGre kernel.

Description:    This is the build script for the simple database functions that are required to support the Materialized View
                fast refresh process.

                This script contains functions that can run standalone and must therefore be run before the complex functions can
                be created.

Notes:          The functions in this script should be maintained in alphabetic order.
                All functions must be created with SECURITY DEFINER to ensure they run with the privileges of the owner.

Issues:         There is a bug in RDS for PostGres version 10.4 that prevents queries against the information_schema,
                this bug is fixed in versions 10.5 and 10.3

                https://forums.aws.amazon.com/thread.jspa?messageID=860564

Debug:          Add a variant of the following command anywhere you need some debug inforaiton
                RAISE NOTICE '<Funciton Name> % %',  CHR(10), <Variable to be examined>;

************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
***********************************************************************************************************************************/

-- psql -h localhost -p 5432 -d postgres -U pgrs_mview -q -f mvSimpleFunctions.sql

----------------------- Write DROP-FUNCTION-stage scripts ----------------------
SET     CLIENT_MIN_MESSAGES = ERROR;

DROP FUNCTION IF EXISTS mv$addIndexToMvLog$Table;
DROP FUNCTION IF EXISTS mv$addRow$ToMv$Table;
DROP FUNCTION IF EXISTS mv$addRow$ToSourceTable;
DROP FUNCTION IF EXISTS mv$checkIfOuterJoinedTable;
DROP FUNCTION IF EXISTS mv$clearPgMvLogTableBits;
DROP FUNCTION IF EXISTS mv$clearSpentPgMviewLogs;
DROP FUNCTION IF EXISTS mv$createMvLog$Table;
DROP FUNCTION IF EXISTS mv$createMvLogTrigger;
DROP FUNCTION IF EXISTS mv$createPgMv$Table;
DROP FUNCTION IF EXISTS mv$createRow$Column;
DROP FUNCTION IF EXISTS mv$deconstructSqlStatement;
DROP FUNCTION IF EXISTS mv$deleteMaterializedViewRows;
DROP FUNCTION IF EXISTS mv$deletePgMview;
DROP FUNCTION IF EXISTS mv$deletePgMviewLog;
DROP FUNCTION IF EXISTS mv$dropTable;
DROP FUNCTION IF EXISTS mv$dropTrigger;
DROP FUNCTION IF EXISTS mv$dropView;
DROP FUNCTION IF EXISTS mv$extractCompoundViewTables;
DROP FUNCTION IF EXISTS mv$findFirstFreeBit;
DROP FUNCTION IF EXISTS mv$getBitValue;
DROP FUNCTION IF EXISTS mv$getPgMviewLogTableData;
DROP FUNCTION IF EXISTS mv$getPgMviewTableData;
DROP FUNCTION IF EXISTS mv$getPgMviewViewColumns;
DROP FUNCTION IF EXISTS mv$getSourceTableSchema;
DROP FUNCTION IF EXISTS mv$grantSelectPrivileges;
DROP FUNCTION IF EXISTS mv$insertPgMviewLogs;
DROP FUNCTION IF EXISTS mv$replaceCommandWithToken;
DROP FUNCTION IF EXISTS mv$removeRow$FromSourceTable;
DROP FUNCTION IF EXISTS mv$truncateMaterializedView;

----------------------- Write CREATE-FUNCTION-stage scripts --------------------
SET CLIENT_MIN_MESSAGES = NOTICE;

CREATE OR REPLACE
FUNCTION    mv$addIndexToMvLog$Table
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pPgLog$Name     IN      TEXT
            )

    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$addIndexToMvLog$Table
Author:       Mike Revitt
Date:         07/06/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
07/06/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    This function creates the materilized view log table against the source table for the materialized view

Arguments:      IN      pOwner              The owner of the object
                IN      pPgLog$Name         The name of the materialized view log table
                IN      pStorageClause      Optional, storage clause for the materialized view log
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tIndexName      TEXT;
    tSqlStatement   TEXT;

BEGIN
    tIndexName      :=  pPgLog$Name || pConst.UNDERSCORE_CHARACTER  || pConst.BITMAP_COLUMN     ||
                                       pConst.UNDERSCORE_CHARACTER  || pConst.MV_INDEX_SUFFIX;

    tSqlStatement   :=  pConst.CREATE_INDEX || tIndexName           ||
                        pConst.ON_COMMAND   || pOwner               || pConst.DOT_CHARACTER     || pPgLog$Name ||
                                               pConst.OPEN_BRACKET  || pConst.BITMAP_COLUMN     || pConst.CLOSE_BRACKET;

    EXECUTE tSqlStatement;

    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$addIndexToMvLog$Table';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$addRow$ToMv$Table
            (
                pConst              IN      mv$allConstants,
                pOwner              IN      TEXT,
                pPgMvName           IN      TEXT,
                pAliasArray         IN      TEXT[],
                pRowidArray         IN      TEXT[],
                pPgMvColumns        INOUT   TEXT,
                pSelectColumns      INOUT   TEXT
            )
    RETURNS RECORD
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$addRow$ToMv$Table
Author:       Mike Revitt
Date:         15/01/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
15/01/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    For every table that is used to construct this materialized view, add a rowid column to the base table.

Arguments:      IN      pOwner              The owner of the object
                IN      pPgMvName           The name of the "hidden" base table containing the data
                IN      pPgMvColumns        This is the list of view columns to which the rowid columns will be added
                IN      pSelectColumns      The columns from the SQL Statement that created the materialised view
                IN      pAliasArray         An array containing the table aliases that make up the materialized view
Returns:                TEXT                The Select Columns, with the rowid columns added
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tAddColumn      TEXT;
    tCreateIndex    TEXT;
    tIndexName      TEXT;
    tSqlStatement   TEXT;
    tRowidColumn    TEXT;
    iTableArryPos   INT     := 0;

BEGIN

    tAddColumn      :=  pConst.ALTER_TABLE || pOwner || pConst.DOT_CHARACTER || pPgMvName || pConst.NEW_LINE ||
                        pConst.ADD_COLUMN;

    tCreateIndex    := pConst.CREATE_INDEX;

    FOR i IN array_lower( pAliasArray, 1 ) .. array_upper( pAliasArray, 1 )
    LOOP
        tIndexName      := pPgMvName    || pConst.UNDERSCORE_CHARACTER  || pRowidArray[i]       || pConst.MV_INDEX_SUFFIX;
        tSqlStatement   := tAddColumn   || pRowidArray[i]               || pConst.MV_M_ROW$_COLUMN_FORMAT;

        EXECUTE tSqlStatement;

        tSqlStatement   :=  tCreateIndex    || tIndexName               || pConst.ON_COMMAND    ||
                                               pOwner                   || pConst.DOT_CHARACTER || pPgMvName ||
                                               pConst.OPEN_BRACKET      || pRowidArray[i]       || pConst.CLOSE_BRACKET;
        EXECUTE tSqlStatement;

        pPgMvColumns    :=  pPgMvColumns    || pConst.COMMA_CHARACTER   || pRowidArray[i];
        pSelectColumns  :=  pSelectColumns  || pConst.COMMA_CHARACTER   || pAliasArray[i]       || pConst.MV_M_ROW$_COLUMN;
        iTableArryPos   := iTableArryPos + 1;
    END LOOP;

    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$addRow$ToMv$Table';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$addRow$ToSourceTable
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pTableName      IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$addRow$ToSourceTable
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    PostGre does not have a ROWID pseudo column and so a ROWID column has to be added to the source table, ideally this
                should be a hidden column, but I can't find any way of doing this

Arguments:      IN      pOwner              The owner of the object
                IN      pTableName          The name of the materialized view source table
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement TEXT;

BEGIN

    tSqlStatement := pConst.ALTER_TABLE || pOwner || pConst.DOT_CHARACTER || pTableName || pConst.ADD_M_ROW$_COLUMN_TO_TABLE;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$addRow$ToSourceTable';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$checkIfOuterJoinedTable
            (
                pConst              IN      mv$allConstants,
                pTableName          IN      TEXT,
                pOuterTableArray    IN      TEXT[]
            )
    RETURNS BOOLEAN
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$checkIfOuterJoinedTable
Author:       Mike Revitt
Date:         04/04/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
05/06/2019  | M Revitt      | Change ARRAY_UPPER and ARRYA_LOWER to FOREACH ... IN ARRAY
04/04/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Some actions against outer joined tables need to be performed differently, so this function checks to see if the
                table is outer joined

Arguments:      IN      pTableName          The name of the table to check
                IN      pOuterTableArray    The array that holds the list of all outer joined tables in this view
Returns:                BOOLEAN             TRUE if we can find the record, otherwise FALSE
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    bResult     BOOLEAN := FALSE;
    tTableName  TEXT    := NULL;

BEGIN

    FOREACH tTableName IN ARRAY pOuterTableArray
    LOOP
        IF tTableName = pTableName
        THEN
            bResult := TRUE;
        END IF;
    END LOOP;

    RETURN( bResult );

END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$clearPgMvLogTableBits
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pPgLog$Name     IN      TEXT,
                pBit            IN      SMALLINT,
                pMaxSequence    IN      INTEGER
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$clearPgMvLogTableBits
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Bitmaps are how we manage multiple registrations against the same base table, every time the recorded row has been
                applied to the materialized view we remove the bit that signifies the interest from the materialized view log

Arguments:      IN      pOwner              The owner of the object
                IN      pPgLog$Name         The name of the materialized view log table
                IN      pBit                The bit to be cleared from the row
                IN      pSequence           The squence to be cleared from the row
                IN      pRowID              The unique identifier of the row to be modified
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement   TEXT;

BEGIN

    tSqlStatement   := pConst.UPDATE_COMMAND        || pOwner || pConst.DOT_CHARACTER   || pPgLog$Name  ||
                       pConst.SET_COMMAND           || pConst.MV_LOG$_DECREMENT_BITMAP  || pBit         || pConst.CLOSE_BRACKET  ||
                       pConst.WHERE_COMMAND         || pConst.MV_SEQUENCE$_COLUMN       ||
                       pConst.IN_SELECT_COMMAND     || pConst.MV_SEQUENCE$_COLUMN       ||
                       pConst.FROM_COMMAND          || pOwner || pConst.DOT_CHARACTER   || pPgLog$Name  ||
                       pConst.MV_LOG$_WHERE_BITMAP$ ||
                       pConst.AND_COMMAND           || pConst.MV_SEQUENCE$_COLUMN       || pConst.LESS_THAN_EQUAL   ||
                       pMaxSequence                 || pConst.CLOSE_BRACKET;

    EXECUTE tSqlStatement USING pBit, pBit;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$clearPgMvLogTableBits';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$clearSpentPgMviewLogs
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pPgLog$Name     IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$clearSpentPgMviewLogs
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Bitmaps are how we manage multiple registrations against the same base table, once all interested materialized
                views have removed their interest in the materialized log row the bitmap will be set to 0 and can be deleted

Arguments:      IN      pOwner              The owner of the object
                IN      pPgLog$Name         The name of the materialized view log table
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement   TEXT;

BEGIN

    tSqlStatement := pConst.DELETE_FROM || pOwner || pConst.DOT_CHARACTER || pPgLog$Name || pConst.MV_LOG$_WHERE_BITMAP_ZERO;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$clearSpentPgMviewLogs';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$createMvLog$Table
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pPgLog$Name     IN      TEXT,
                pStorageClause  IN      TEXT     DEFAULT NULL
            )

    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$createMvLog$Table
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    This function creates the materilized view log table against the source table for the materialized view

Arguments:      IN      pOwner              The owner of the object
                IN      pPgLog$Name         The name of the materialized view log table
                IN      pStorageClause      Optional, storage clause for the materialized view log
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement TEXT;

BEGIN
    tSqlStatement := pConst.CREATE_TABLE || pOwner || pConst.DOT_CHARACTER || pPgLog$Name || pConst.MV_LOG_COLUMNS;

    IF pStorageClause IS NOT NULL
    THEN
        tSqlStatement := tSqlStatement || pStorageClause;
    END IF;

    EXECUTE tSqlStatement;

    RETURN;


    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$createMvLog$Table';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$createMvLogTrigger
            (
                pConst              IN      mv$allConstants,
                pOwner              IN      TEXT,
                pTableName          IN      TEXT,
                pMvTriggerName      IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$createMvLogTrigger
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    After the materialized view log table has been created a trigger is required on the source table to populate the
                materialized view log

Arguments:      IN      pOwner              The owner of the object
                IN      pTableName          The name of the materialized view source table
                IN      pMvTriggerName      The name of the materialized view source trigger
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement TEXT;

BEGIN

    tSqlStatement :=    pConst.TRIGGER_CREATE          || pMvTriggerName   ||
                        pConst.TRIGGER_AFTER_DML       || pOwner           || pConst.DOT_CHARACTER  || pTableName ||
                        pConst.TRIGGER_FOR_EACH_ROW;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$createMvLogTrigger';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$createPgMv$Table
            (
                pConst              IN      mv$allConstants,
                pOwner              IN      TEXT,
                pPgMvName           IN      TEXT,
                pViewColumns        IN      TEXT,
                pSelectColumns      IN      TEXT,
                pTableNames         IN      TEXT,
                pStorageClause      IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$createPgMv$Table
Author:       Mike Revitt
Date:         16/01/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
16/01/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Creates the base table upon which the Materialized View will be based from the provided SQL statment

Note:           This function requires the SEARCH_PATH to be set to the current value so that the select statement can find the
                source tables.
                The default for PostGres functions is to not use the search path when executing with the privileges of the creator

Arguments:      IN      pOwner              The owner of the object
                IN      pPgMvName           The name of the materialized view base table
                IN      pViewColumns        Allow the view to be created with different names to the base table
                                            This list is positional so must match the position and number of columns in the
                                            select statment
                IN      pSelectColumns      The column list from the SQL query that will be used to create the view
                IN      pTableNames         The string between the FROM and WHERE clauses in the SQL query
                IN      pStorageClause      Optional, storage clause for the materialized view
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement   TEXT    := NULL;
    tViewColumns    TEXT    := NULL;
    tStorageClause  TEXT    := NULL;

BEGIN

    IF pViewColumns IS NOT NULL
    THEN
        tViewColumns := pConst.OPEN_BRACKET ||
                        REPLACE( REPLACE( pViewColumns,
                            pConst.OPEN_BRACKET  , NULL ),
                            pConst.CLOSE_BRACKET , NULL ) ||
                        pConst.CLOSE_BRACKET;
    ELSE
        tViewColumns := pConst.SPACE_CHARACTER;
    END IF;

    IF pStorageClause IS NOT NULL
    THEN
        tStorageClause := pStorageClause;
    ELSE
        tStorageClause := pConst.SPACE_CHARACTER;
    END IF;

    tSqlStatement   :=  pConst.CREATE_TABLE     || pOwner          || pConst.DOT_CHARACTER || pPgMvName || tViewColumns  ||
                        pConst.AS_COMMAND       ||
                        pConst.SELECT_COMMAND   || pSelectColumns  ||
                        pConst.FROM_COMMAND     || pTableNames     ||
                        pConst.WHERE_NO_DATA    || tStorageClause;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$createPgMv$Table';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$createRow$Column
            (
                pConst      IN      mv$allConstants,
                pTableName  IN      TEXT
            )
    RETURNS TEXT
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$createRow$Column
Author:       Mike Revitt
Date:         15/01/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
15/01/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    For every table that is used to construct this materialized view, add a rowid column to the base table.

Arguments:      IN      pOwner              The owner of the object
                IN      pPgMvName           The name of the "hidden" base table containing the data
                IN      pPgMvColumns        This is the list of view columns to which the rowid columns will be added
                IN      pSelectColumns      The columns from the SQL Statement that created the materialised view
                IN      pTableArray         An array containing the table names that make up the materialized view
Returns:                TEXT                The Select Columns, with the rowid columns added
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tAddColumn      TEXT;
    tCreateIndex    TEXT;
    tIndexName      TEXT;
    tSqlStatement   TEXT;
    tRowidColumn    TEXT;
    iTableArryPos   INT     := 0;

BEGIN

    tRowidColumn := SUBSTRING( pTableName, 1, pConst.MV_MAX_BASE_TABLE_LEN ) || pConst.UNDERSCORE_CHARACTER ||
                                                                                pConst.MV_M_ROW$_COLUMN;

    RETURN( tRowidColumn );
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$deconstructSqlStatement
            (
                pConst              IN      mv$allConstants,
                pSqlStatement       IN      TEXT,
                pTableNames           OUT   TEXT,
                pSelectColumns        OUT   TEXT,
                pWhereClause          OUT   TEXT
            )
    RETURNS RECORD
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$deconstructSqlStatement
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    One of the most difficult tasks with the materialized view fast refresh process is programatically determining
                the columns, base tables and select criteria that have been used to construct the view.

                This function deconstructs the SQL statement that was used to create the materialized view and stores the
                information in the data dictionary tables for future use

Notes:          The technique used here is to search for each of the key words in a SQL statement, FROM, WHERE and replace them
                whith an unprintable character which can be search for later.

                To locate the keywords they are searched for with acceptable command delimination characters either side of the
                key word, SPACE, NEW LINE, CARRIAGE RETURN

                The SELECT keyword is assumed to be the leading key word and is simply removed from the string with the use of a
                SUBSTRING command

                Once all of the replacements have been completed it becomes a simple task to extract the necessary information

Arguments:      IN      pSqlStatement       The SQL Statement used to create the materialized view
                    OUT pTableNames         The name of the materialized view source table
                    OUT pSelectColumns      The list of columns in the SQL Statement used to create the materialized view
                    OUT pWhereClause        The where clause from the SQL Statement used to create the materialized view
Returns:                RECORD              The three out parameters
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement   TEXT := pSqlStatement;

BEGIN
    tSqlStatement := SUBSTRING( tSqlStatement,  POSITION( pConst.SELECT_DML_TYPE IN tSqlStatement ) +
                                                LENGTH(   pConst.SELECT_DML_TYPE ));

    tSqlStatement := TRIM( LEADING pConst.SPACE_CHARACTER FROM tSqlStatement );

    tSqlStatement := mv$replaceCommandWithToken( pConst, tSqlStatement,    pConst.FROM_DML_TYPE,    pConst.FROM_TOKEN  );
    tSqlStatement := mv$replaceCommandWithToken( pConst, tSqlStatement,    pConst.WHERE_DML_TYPE,   pConst.WHERE_TOKEN );

    tSqlStatement := tSqlStatement || pConst.WHERE_TOKEN; -- In case Where does not appear in the string

    pTableNames   := TRIM(  SUBSTRING( tSqlStatement,
                            POSITION(  pConst.FROM_TOKEN  IN tSqlStatement )  + LENGTH( pConst.FROM_TOKEN ),
                            POSITION(  pConst.WHERE_TOKEN IN tSqlStatement )  -
                                LENGTH(    pConst.WHERE_TOKEN )                -
                                POSITION(  pConst.FROM_TOKEN IN tSqlStatement )));

    pSelectColumns := TRIM( SUBSTRING( tSqlStatement,
                            1,
                            POSITION(  pConst.FROM_TOKEN  IN tSqlStatement )  - LENGTH( pConst.FROM_TOKEN )));

    pWhereClause   := TRIM( SUBSTRING( tSqlStatement,
                            POSITION(  pConst.WHERE_TOKEN IN tSqlStatement )  + LENGTH( pConst.WHERE_TOKEN )));

    IF  LENGTH( pWhereClause ) > 0
    AND POSITION( pConst.WHERE_TOKEN IN pWhereClause ) > 0
    THEN
        pWhereClause   := TRIM( SUBSTRING( pWhereClause,
                                1,
                                POSITION( pConst.WHERE_TOKEN IN pWhereClause ) - LENGTH( pConst.WHERE_TOKEN )));
    END IF;

    RETURN;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$deleteMaterializedViewRows
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pPgMvName       IN      TEXT,
                pRowidColumn    IN      TEXT,
                pRowIDs         IN      UUID[]
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$deleteMaterializedViewRows
Author:       Mike Revitt
Date:         12/011/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Gets called to remove the row from the Materialized View when a delete is detected

Arguments:      IN      pOwner              The owner of the object
                IN      pPgMvName           The name of the underlying table for the materialized view
                IN      pRowidColumn        The rowid column for this table in the base table
                IN      pRowID              The unique identifier to locate the modified row
Returns:                VOID

************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement   TEXT;

BEGIN

    tSqlStatement :=    pConst.DELETE_FROM || pOwner  || pConst.DOT_CHARACTER   || pPgMvName        ||
                        pConst.WHERE_COMMAND          || pRowidColumn           || pConst.IN_ROWID_LIST;

    EXECUTE tSqlStatement
    USING   pRowIDs;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$deleteMaterializedViewRows';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$deletePgMview
            (
                pOwner      IN      TEXT,
                pViewName   IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$deletePgMview
Author:       Mike Revitt
Date:         04/06/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
04/06/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Every time a new materialized view is created, a record of that view is also created in the data dictionary table
                mike$_pgmviews.

                This table holds all of the pertinent information about the materialized view which is later used in the management
                of that view.

Arguments:      IN      pOwner              The owner of the object
                IN      pViewName           The name of the materialized view
Returns:                VOID

************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

BEGIN

    DELETE
    FROM    mike$_pgmviews
    WHERE
            owner       = pOwner
    AND     view_name   = pViewName;

    RETURN;
    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$deletePgMview';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE EXCEPTION '%',                SQLSTATE;

END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$deletePgMviewLog
            (
                pOwner      IN      TEXT,
                pTableName  IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$deletePgMviewLog
Author:       Mike Revitt
Date:         04/06/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
04/06/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Every time a new materialized view is created, a record of that view is also created in the data dictionary table
                mike$_pgmviews.

                This table holds all of the pertinent information about the materialized view which is later used in the management
                of that view.

Arguments:      IN      pOwner              The owner of the object
                IN      pViewName           The name of the materialized view
Returns:                VOID

************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

BEGIN

    DELETE
    FROM    pgmview_logs
    WHERE
            owner       = pOwner
    AND     table_name  = pTableName;

    RETURN;
    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$deletePgMviewLog';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE EXCEPTION '%',                SQLSTATE;

END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$insertPgMviewLogs
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pPgLog$Name     IN      TEXT,
                pTableName      IN      TEXT,
                pTriggerName    IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$insertPgMviewLogs
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    inserts the row into the materialized view log data dictionary table

Arguments:      IN      pOwner              The owner of the object
                IN      pPgLog$Name         The name of the materialized view log table
                IN      pTableName          The name of the materialized view source table
                IN      pMvSequenceName     The name of the materialized view sequence
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
BEGIN

    INSERT  INTO
            pgmview_logs
            (
                owner,  pglog$_name, table_name, trigger_name
            )
    VALUES  (
                pOwner, pPgLog$Name, pTableName, pTriggerName
            );

    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$insertPgMviewLogs';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$dropTable
            (
                pConst              IN      mv$allConstants,
                pOwner              IN      TEXT,
                pTableName          IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$dropTable
Author:       Mike Revitt
Date:         04/06/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
04/06/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Creates the base table upon which the Materialized View will be based from the provided SQL statment

Note:           This function requires the SEARCH_PATH to be set to the current value so that the select statement can find the
                source tables.
                The default for PostGres functions is to not use the search path when executing with the privileges of the creator

Arguments:      IN      pOwner              The owner of the object
                IN      pTableName          The name of the materialized view base table
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement   TEXT    := NULL;

BEGIN

    tSqlStatement   :=  pConst.DROP_TABLE || pOwner || pConst.DOT_CHARACTER || pTableName;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$dropTable';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$dropTrigger
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pTriggerName    IN      TEXT,
                pTableName      IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$dropTrigger
Author:       Mike Revitt
Date:         04/06/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    After the materialized view log table has been created a trigger is required on the source table to populate the
                materialized view log

Arguments:      IN      pOwner              The owner of the object
                IN      pTableName          The name of the materialized view source table
                IN      pTriggerName        The name of the materialized view source trigger
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement TEXT;

BEGIN

    tSqlStatement := pConst.TRIGGER_DROP || pTriggerName || pConst.ON_COMMAND || pOwner || pConst.DOT_CHARACTER || pTableName;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$dropTrigger';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$dropView
            (
                pConst      IN      mv$allConstants,
                pOwner      IN      TEXT,
                pViewName   IN      TEXT
            )
    RETURNS TEXT
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$dropView
Author:       Mike Revitt
Date:         04/06/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
04/06/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Creates the materialised view as a select * from the PgMv$ base table before the rowid columns are added

Arguments:      IN      pOwner              The owner of the object
                IN      pViewName           The name of the materialized view
                IN      pPgMvName           The name of the materialized view base table (pgmv$ table)
Returns:                TEXT                The list of columns in the newly created view
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    cResult         CHAR(1);
    tSqlStatement   TEXT    := NULL;
    tViewColumns    TEXT    := NULL;

BEGIN

    tSqlStatement   :=  pConst.DROP_VIEW || pOwner || pConst.DOT_CHARACTER  || pViewName;

    EXECUTE tSqlStatement;

    RETURN tViewColumns;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$dropView';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$extractCompoundViewTables
            (
                pConst              IN      mv$allConstants,
                pTableNames         IN      TEXT,
                pTableArray           OUT   TEXT[],
                pAliasArray           OUT   TEXT[],
                pRowidArray           OUT   TEXT[],
                pOuterTableArray      OUT   TEXT[],
                pParentTableArray     OUT   TEXT[],
                pParentAliasArray     OUT   TEXT[],
                pParentRowidArray     OUT   TEXT[]
            )
    RETURNS RECORD
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$extractCompoundViewTables
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    One of the most difficult tasks with the materialized view fast refresh process is programatically determining
                the columns, base tables and select criteria that have been used to construct the view.

                This function deconstructs the FROM clause that was used to create the materialized view and determines the
                primary table and a complete list of all tables involved in the query

Notes:          The technique used here is to search for each of the key words in FROM clause, COMMA, RIGHT, ON, JOIN and replace
                them with an unprintable character which can be search for later.

                To locate the keywords they are searched for with acceptable command delimination characters either side of the
                key word, SPACE, NEW LINE, CARRIAGE RETURN

                Once all of the replacements have been completed it becomes a simple task to extract the necessary information

PostGres Notes:
            Qualified joins
                T1 { [INNER] | { LEFT | RIGHT | FULL } [OUTER] } JOIN T2 ON boolean_expression
                T1 { [INNER] | { LEFT | RIGHT | FULL } [OUTER] } JOIN T2 USING ( join column list )
                T1 NATURAL { [INNER] | { LEFT | RIGHT | FULL } [OUTER] } JOIN T2
                The words INNER and OUTER are optional in all forms.
                INNER is the default; LEFT, RIGHT, and FULL imply an outer join.

                The join condition is specified in the ON or USING clause, or implicitly by the word NATURAL. The join condition
                determines which rows from the two source tables are considered to “match”, as explained in detail below.

                The possible types of qualified join are:

            INNER JOIN
                For each row R1 of T1, the joined table has a row for each row in T2 that satisfies the join condition with R1.

            LEFT OUTER JOIN
                First, an inner join is performed. Then, for each row in T1 that does not satisfy the join condition with any row
                in T2, a joined row is added with null values in columns of T2. Thus, the joined table always has at least one row
                for each row in T1.

            RIGHT OUTER JOIN
                First, an inner join is performed. Then, for each row in T2 that does not satisfy the join condition with any row
                in T1, a joined row is added with null values in columns of T1. This is the converse of a left join: the
                result table will always have a row for each row in T2.

            FULL OUTER JOIN
                First, an inner join is performed. Then, for each row in T1 that does not satisfy the join condition with any row
                in T2, a joined row is added with null values in columns of T2. Also, for each row of T2 that does not satisfy the
                join condition with any row in T1, a joined row with null values in the columns of T1 is added.

            ON CLAUSE
                The ON clause is the most general kind of join condition: it takes a Boolean value expression of the same kind as
                is used in a WHERE clause. A pair of rows from T1 and T2 match if the ON expression evaluates to true.

            USING CLAUSE
                The USING clause is a shorthand that allows you to take advantage of the specific situation where both sides of the
                join use the same name for the joining column(s). It takes a comma-separated list of the shared column names and
                forms a join condition that includes an equality comparison for each one. For example, joining T1 and T2 with USING
                (a, b) produces the join condition ON T1.a = T2.a AND T1.b = T2.b.

                Furthermore, the output of JOIN USING suppresses redundant columns: there is no need to print both of the matched
                columns, since they must have equal values. While JOIN ON produces all columns from T1 followed by all columns
                from T2, JOIN USING produces one output column for each of the listed column pairs (in the listed order), followed
                by any remaining columns from T1, followed by any remaining columns from T2.

                Finally, NATURAL is a shorthand form of USING: it forms a USING list consisting of all column names that appear in
                both input tables. As with USING, these columns appear only once in the output table. If there are no common
                column names, NATURAL JOIN behaves like JOIN ... ON TRUE, producing a cross-product join.

Arguments:      IN      pSqlStatement       The SQL Statement used to create the materialized view
                    OUT pTableNames         The name of the materialized view source table
                    OUT pSelectColumns      The list of columns in the SQL Statement used to create the materialized view
                    OUT pWhereClause        The where clause from the SQL Statement used to create the materialized view
Returns:                RECORD              The three out parameters
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tOuterTable             TEXT    := NULL;
    tParentAlias            TEXT    := pConst.NO_PARENT_TOKEN;
    tParentRowid            TEXT    := pConst.NO_PARENT_TOKEN;
    tParentTable            TEXT    := pConst.NO_PARENT_TOKEN;
    tTableName              TEXT;
    tTableNames             TEXT;
    tTableAlias             TEXT;
    iTableArryPos           INTEGER := 0;

BEGIN
--  Replacing a single space with a double space is only required on the first pass to ensure that there is padding around all
--  special commands so we can find then in the future replace statments
    tTableNames :=  REPLACE(                            pTableNames, pConst.SPACE_CHARACTER,  pConst.DOUBLE_SPACE_CHARACTERS );
    tTableNames :=  mv$replaceCommandWithToken( pConst, tTableNames, pConst.JOIN_DML_TYPE,    pConst.JOIN_TOKEN );
    tTableNames :=  mv$replaceCommandWithToken( pConst, tTableNames, pConst.ON_DML_TYPE,      pConst.ON_TOKEN );
    tTableNames :=  mv$replaceCommandWithToken( pConst, tTableNames, pConst.OUTER_DML_TYPE,   pConst.OUTER_TOKEN );
    tTableNames :=  mv$replaceCommandWithToken( pConst, tTableNames, pConst.INNER_DML_TYPE,   pConst.COMMA_CHARACTER );
    tTableNames :=  mv$replaceCommandWithToken( pConst, tTableNames, pConst.LEFT_DML_TYPE,    pConst.COMMA_LEFT_TOKEN );
    tTableNames :=  mv$replaceCommandWithToken( pConst, tTableNames, pConst.RIGHT_DML_TYPE,   pConst.RIGHT_COMMA_TOKEN );
    tTableNames :=  REPLACE( REPLACE(                   tTableNames, pConst.NEW_LINE,         pConst.EMPTY_STRING ),
                                                                     pConst.CARRIAGE_RETURN,  pConst.EMPTY_STRING );

    tTableNames :=  tTableNames || pConst.COMMA_CHARACTER; -- A trailling comma is required so we can detect the final table

    WHILE POSITION( pConst.COMMA_CHARACTER IN tTableNames ) > 0
    LOOP
        tOuterTable     := NULL;
        tParentAlias    := pConst.NO_PARENT_TOKEN;
        tParentRowid    := pConst.NO_PARENT_TOKEN;
        tParentTable    := pConst.NO_PARENT_TOKEN;

        tTableName :=  LTRIM( SPLIT_PART( tTableNames, pConst.COMMA_CHARACTER, 1 ));

        IF POSITION( pConst.RIGHT_TOKEN IN tTableName ) > 0
        THEN
            tOuterTable  := pTableArray[iTableArryPos - 1];
            tParentAlias := NULL;
            tParentRowid := NULL;
            tParentTable := NULL;

        ELSIF POSITION( pConst.LEFT_TOKEN IN tTableName ) > 0
        THEN
            tParentAlias := pAliasArray[iTableArryPos - 1];
            tParentRowid := mv$createRow$Column( pConst, pTableArray[iTableArryPos - 1] );
            tParentTable := pTableArray[iTableArryPos - 1];
            tOuterTable  := TRIM( SUBSTRING( tTableName,
                                             POSITION( pConst.JOIN_TOKEN   IN tTableName ) + LENGTH( pConst.JOIN_TOKEN),
                                             POSITION( pConst.ON_TOKEN     IN tTableName ) - LENGTH( pConst.ON_TOKEN)
                                             - POSITION( pConst.JOIN_TOKEN IN tTableName )));
        END IF;

        -- The LEFT, RIGHT and JOIN tokens are only required for outer join pattern matching
        tTableName  := REPLACE( tTableName, pConst.JOIN_TOKEN,  pConst.EMPTY_STRING );
        tTableName  := REPLACE( tTableName, pConst.LEFT_TOKEN,  pConst.EMPTY_STRING );
        tTableName  := REPLACE( tTableName, pConst.RIGHT_TOKEN, pConst.EMPTY_STRING );
        tTableName  := REPLACE( tTableName, pConst.OUTER_TOKEN, pConst.EMPTY_STRING );
        tTableName  := LTRIM(   tTableName );

        pTableArray[iTableArryPos]  := (REGEXP_SPLIT_TO_ARRAY( tTableName,  pConst.REGEX_MULTIPLE_SPACES ))[1];
        tTableAlias                 := (REGEXP_SPLIT_TO_ARRAY( tTableName,  pConst.REGEX_MULTIPLE_SPACES ))[2];
        pRowidArray[iTableArryPos]  :=  mv$createRow$Column( pConst, pTableArray[iTableArryPos] );
        pAliasArray[iTableArryPos]  :=  COALESCE( NULLIF( NULLIF( tTableAlias, pConst.EMPTY_STRING), pConst.ON_TOKEN),
                                                                  pTableArray[iTableArryPos] ) || pConst.DOT_CHARACTER;

        pOuterTableArray[iTableArryPos]  :=(REGEXP_SPLIT_TO_ARRAY( tOuterTable, pConst.REGEX_MULTIPLE_SPACES ))[1];
        pParentTableArray[iTableArryPos] := NULLIF( COALESCE( tParentTable, pTableArray[iTableArryPos] ), pConst.NO_PARENT_TOKEN );
        pParentAliasArray[iTableArryPos] := NULLIF( COALESCE( tParentAlias, pAliasArray[iTableArryPos] ), pConst.NO_PARENT_TOKEN );
        pParentRowidArray[iTableArryPos] := NULLIF( COALESCE( tParentRowid, pRowidArray[iTableArryPos] ), pConst.NO_PARENT_TOKEN );

        tTableNames     := TRIM( SUBSTRING( tTableNames,
                                 POSITION( pConst.COMMA_CHARACTER IN tTableNames ) + LENGTH( pConst.COMMA_CHARACTER )));
        iTableArryPos   := iTableArryPos + 1;

    END LOOP;

    RETURN;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$findFirstFreeBit
            (
                pConst      IN      mv$allConstants,
                pBitMap     IN      INTEGER
            )
    RETURNS INTEGER
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$findFirstFreeBit
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    When a new materialized view is registered against a base table, it is assigned a unique bit against which all
                interest is registered.

                The bit that is assigned is the lowest value bit that has not yet been assigned, as long as that balue is lower
                then the maximum number of PgMviews per table

Arguments:      IN      pBitMap             The bit map value constructed from assigned bits
Returns:                INTEGER             The next free bit
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    iBit        SMALLINT    := pConst.FIRST_PGMVIEW_BIT;
    iBitNotSet  INTEGER     := pConst.BIT_NOT_SET;

BEGIN

    WHILE( pBitMap & POWER( pConst.BASE_TWO, iBit )::INTEGER ) <> iBitNotSet
    AND pConst.MAX_PGMVIEWS_PER_TABLE >= iBit
    LOOP
        iBit := iBit + 1;
    END LOOP;

    IF pConst.MAX_PGMVIEWS_PER_TABLE < iBit
    THEN
        RAISE EXCEPTION 'Maximum number of PgMviews (%s) for table exceeded', pConst.MAX_PGMVIEWS_PER_TABLE;
    ELSE
        RETURN( iBit );
    END IF;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$getBitValue
            (
                pConst  IN      mv$allConstants,
                pBit    IN      SMALLINT
            )
    RETURNS INTEGER
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$getBitValue
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Converts a bit into it's binary value.

Arguments:      IN      pBit                The bit
Returns:                INTEGER             The binary value of that bit
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    iBitValue   INTEGER := 0;

BEGIN

    iBitValue := POWER( pConst.BASE_TWO, pBit );
    RETURN( iBitValue );
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$getPgMviewLogTableData
            (
                pConst      IN      mv$allConstants,
                pOwner      IN      TEXT,
                pTableName  IN      TEXT
            )
    RETURNS pgmview_logs
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$getPgMviewLogTableData
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Returns all of the data stored in the data dictionary about this materialized view log.

Arguments:      IN      pOwner              The owner of the object
                IN      pPgLog$Name         The name of the materialized view log table
Returns:                RECORD              The row of data from the data dictionary relating to this materialized view log
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    aPgMviewLog            pgmview_logs;

    cgetPgMviewLogTableData    CURSOR
    FOR
    SELECT
            *
    FROM    pgmview_logs
    WHERE   owner       = pOwner
    AND     table_name  = pTableName;

BEGIN
    OPEN    cgetPgMviewLogTableData;
    FETCH   cgetPgMviewLogTableData
    INTO    aPgMviewLog;
    CLOSE   cgetPgMviewLogTableData;

    IF aPgMviewLog.table_name IS NULL
    THEN
        RAISE EXCEPTION 'Materialised View ''%'' does not have a PgMview Log', pOwner || pConst.DOT_CHARACTER || pTableName;
    ELSE
        RETURN( aPgMviewLog );
    END IF;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$getPgMviewLogTableData
            (
                pConst      IN      mv$allConstants,
                pTableName  IN      TEXT
            )
    RETURNS pgmview_logs
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$getPgMviewLogTableData
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Returns all of the data stored in the data dictionary about this materialized view log.

Note:           This function is used when the table owner is not know
                This function also requires the SEARCH_PATH to be set to the current value so that the select statement can find
                the source tables.
                The default for PostGres functions is to not use the search path when executing with the privileges of the creator


Arguments:      IN      pPgLog$Name         The name of the materialized view log table
Returns:                RECORD              The row of data from the data dictionary relating to this materialized view log
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tOwner      TEXT    := NULL;

BEGIN

    tOwner  := mv$getSourceTableSchema( pConst, pTableName );

    RETURN( mv$getPgMviewLogTableData( pConst, tOwner, pTableName ));

END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$getPgMviewTableData
            (
                pConst      IN      mv$allConstants,
                pOwner      IN      TEXT,
                pViewName   IN      TEXT
            )
    RETURNS PgMviews
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$getPgMviewTableData
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Returns all of the data stored in the data dictionary about this materialized view.

Arguments:      IN      pOwner              The owner of the object
                IN      pViewName           The name of the materialized view
Returns:                RECORD              The row of data from the data dictionary relating to this materialized view

************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE
    aPgMview           PgMviews;

    cgetPgMviewTableData   CURSOR
    FOR
    SELECT
            *
    FROM    PgMviews
    WHERE   owner       = pOwner
    AND     view_name   = pViewName;
BEGIN
    OPEN    cgetPgMviewTableData;
    FETCH   cgetPgMviewTableData
    INTO    aPgMview;
    CLOSE   cgetPgMviewTableData;

    IF 0 = cardinality( aPgMview.table_array )
    THEN
        RAISE EXCEPTION 'Materialised View ''%'' does not have a base table', pOwner || pConst.DOT_CHARACTER || pViewName;
    ELSE
        RETURN( aPgMview );
    END IF;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$getPgMviewViewColumns
            (
                pConst      IN      mv$allConstants,
                pOwner      IN      TEXT,
                pViewName   IN      TEXT
            )
    RETURNS TEXT
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$getPgMviewViewColumns
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    The easiest way to get the names of the columns that have been created, it is possible that the select statement
                used aliases, is to extract them from the data dictionary table after creation. Which is what I am doing here.

Notes:          Because the final column is always the ROWID column, we add that manually at the end

Arguments:      IN      pOwner              The owner of the object
                IN      pViewName           The name of the materialized view
Returns:                TEXT                A comma delimited string of the column names in the materialized view

************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tColumnNames            TEXT    := '';  -- Has to be initialised to work in loop
    rPgMviewColumnNames     RECORD;

BEGIN

    FOR rPgMviewColumnNames
    IN
        SELECT
                column_name
        FROM    information_schema.columns
        WHERE   table_schema    = LOWER( pOwner )
        AND     table_name      = LOWER( pViewName )
    LOOP
        tColumnNames := tColumnNames || rPgMviewColumnNames.column_name || pConst.COMMA_CHARACTER;
    END LOOP;

    IF tColumnNames IS NULL
    THEN
        RAISE EXCEPTION 'Materialised View ''%'' does not have any columns', pOwner || pConst.DOT_CHARACTER || pViewName;
    ELSE
        tColumnNames   := LEFT( tColumnNames,  LENGTH( tColumnNames  ) - 1 );  -- Remove trailing comma
        RETURN( tColumnNames );
    END IF;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$getSourceTableSchema
            (
                pConst      IN      mv$allConstants,
                pTableName  IN      TEXT
            )
    RETURNS TEXT
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$getSourceTableSchema
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
21/02/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Looks down the search path to determine which schema is being used to locate the table.

Note:           This function also requires the SEARCH_PATH to be set to the current value so that the select statement can find
                the source tables.
                The default for PostGres functions is to not use the search path when executing with the privileges of the creator

Arguments:      IN      pTableName          The name of the table we are trying to locate
Returns:                TEXT                The name of the schema where the table was located
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tOwner      TEXT    := NULL;
    tTableList  TEXT;
    tSearchPath TEXT[];

    cGetOwner   CURSOR( cTableName TEXT, cSchemaName TEXT )
    FOR
        SELECT
                table_schema
        FROM
                information_schema.tables
        WHERE
                table_name      = cTableName
        AND     table_schema    = cSchemaName;
BEGIN

    tTableList  :=  CURRENT_SCHEMAS( FALSE );
    tTableList  :=  REPLACE( REPLACE( REPLACE( tTableList,
                    pConst.LEFT_BRACE_CHARACTER,      pConst.EMPTY_STRING),
                    pConst.RIGHT_BRACE_CHARACTER,     pConst.EMPTY_STRING),
                    pConst.COMMA_CHARACTER,           pConst.SPACE_CHARACTER);
    tSearchPath :=  REGEXP_SPLIT_TO_ARRAY( tTableList,  pConst.REGEX_MULTIPLE_SPACES);

    FOR i IN array_lower( tSearchPath, 1 ) .. array_upper( tSearchPath, 1 )
    LOOP
        IF  tOwner IS NULL
        THEN
            OPEN    cGetOwner( pTableName, tSearchPath[i] );
            FETCH   cGetOwner
            INTO    tOwner;
            CLOSE   cGetOwner;
        END IF;
    END LOOP;

    IF tOwner IS NULL
    THEN
        RAISE INFO      'Exception in function mv$getSourceTableSchema';
        RAISE EXCEPTION 'Table ''%'' can not be located in the search path', pTableName;
    ELSE
        RETURN( tOwner );
    END IF;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$grantSelectPrivileges
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pObjectName     IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$grantSelectPrivileges
Author:       Mike Revitt
Date:         21/02/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    Whilst objects are created into the named schema, the ownership remains with the package owner, pgrs_mview, so in
                order to allow other users to access these materialized views it is necessary to grant select privileges to the
                default role 'PGMV_ROLE_NAME'

Arguments:      IN      pOwner              The owner of the object
                IN      pObjectName         The name of the object to receive select privileges
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement TEXT;

BEGIN

    tSqlStatement :=    pConst.GRANT_SELECT_ON    || pOwner   || pConst.DOT_CHARACTER   || pObjectName  ||
                        pConst.TO_COMMAND                     || pConst.PGMV_SELECT_ROLE;

    EXECUTE tSqlStatement;

    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$grantSelectPrivileges';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$insertPgMviewLogs
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pPgLog$Name     IN      TEXT,
                pTableName      IN      TEXT,
                pTriggerName    IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$insertPgMviewLogs
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    inserts the row into the materialized view log data dictionary table

Arguments:      IN      pOwner              The owner of the object
                IN      pPgLog$Name         The name of the materialized view log table
                IN      pTableName          The name of the materialized view source table
                IN      pMvSequenceName     The name of the materialized view sequence
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
BEGIN

    INSERT  INTO
            pgmview_logs
            (
                owner,  pglog$_name, table_name, trigger_name
            )
    VALUES  (
                pOwner, pPgLog$Name, pTableName, pTriggerName
            );

    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$insertPgMviewLogs';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$removeRow$FromSourceTable
            (
                pConst          IN      mv$allConstants,
                pOwner          IN      TEXT,
                pTableName      IN      TEXT
            )
    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$removeRow$FromSourceTable
Author:       Mike Revitt
Date:         04/06/2019
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
04/06/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    PostGre does not have a ROWID pseudo column and so a ROWID column has to be added to the source table, ideally this
                should be a hidden column, but I can't find any way of doing this

Arguments:      IN      pOwner              The owner of the object
                IN      pTableName          The name of the materialized view source table
Returns:                VOID
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement TEXT;

BEGIN

    tSqlStatement := pConst.ALTER_TABLE || pOwner || pConst.DOT_CHARACTER || pTableName || pConst.DROP_M_ROW$_COLUMN_FROM_TABLE;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$removeRow$FromSourceTable';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$replaceCommandWithToken
            (
                pConst          IN      mv$allConstants,
                pSearchString   IN      TEXT,
                pSearchValue    IN      TEXT,
                pTokan          IN      TEXT
            )
    RETURNS TEXT
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$replaceCommandWithToken
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
15/01/2019  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    A huge amount of coding in this program is to locate specific key words within text strings. This is largely a
                repetative process which I have now moved to a common function


Arguments:      IN      pSearchString       The string to be searched
                IN      pSearchValue        The value to look for in the string
                IN      pTokan              The value to replace the search value with within the string
Returns:                TEXT                The tokanised string
************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tTokanisedString    TEXT;

BEGIN

    tTokanisedString :=
        REPLACE( REPLACE( REPLACE( REPLACE( REPLACE( REPLACE( REPLACE( REPLACE( REPLACE(
        pSearchString,
        pConst.SPACE_CHARACTER || pSearchValue  || pConst.SPACE_CHARACTER,   pTokan ),
        pConst.SPACE_CHARACTER || pSearchValue  || pConst.NEW_LINE,          pTokan ),
        pConst.SPACE_CHARACTER || pSearchValue  || pConst.CARRIAGE_RETURN,   pTokan ),
        pConst.NEW_LINE        || pSearchValue  || pConst.SPACE_CHARACTER,   pTokan ),
        pConst.NEW_LINE        || pSearchValue  || pConst.NEW_LINE,          pTokan ),
        pConst.NEW_LINE        || pSearchValue  || pConst.CARRIAGE_RETURN,   pTokan ),
        pConst.CARRIAGE_RETURN || pSearchValue  || pConst.SPACE_CHARACTER,   pTokan ),
        pConst.CARRIAGE_RETURN || pSearchValue  || pConst.NEW_LINE,          pTokan ),
        pConst.CARRIAGE_RETURN || pSearchValue  || pConst.CARRIAGE_RETURN,   pTokan );

    RETURN( tTokanisedString );

END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;
------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE
FUNCTION    mv$truncateMaterializedView
            (
                pConst      IN      mv$allConstants,
                pOwner      IN      TEXT,
                pPgMvName   IN      TEXT
            )

    RETURNS VOID
AS
$BODY$
/* ---------------------------------------------------------------------------------------------------------------------------------
Routine Name: mv$truncateMaterializedView
Author:       Mike Revitt
Date:         12/11/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name          | Description
------------+---------------+-------------------------------------------------------------------------------------------------------
            |               |
11/03/2018  | M Revitt      | Initial version
------------+---------------+-------------------------------------------------------------------------------------------------------
Description:    When performing a full refresh, we first have to truncate the materialized view

Arguments:      IN      pOwner              The owner of the object
                IN      pPgMvName          The name of the materialized view base table
Returns:                VOID

************************************************************************************************************************************
Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0
***********************************************************************************************************************************/
DECLARE

    tSqlStatement TEXT;

BEGIN
    tSqlStatement := pConst.TRUNCATE_TABLE || pOwner || pConst.DOT_CHARACTER || pPgMvName;

    EXECUTE tSqlStatement;
    RETURN;

    EXCEPTION
    WHEN OTHERS
    THEN
        RAISE INFO      'Exception in function mv$truncateMaterializedView';
        RAISE INFO      'Error %:- %:',     SQLSTATE, SQLERRM;
        RAISE INFO      'Error Context:% %',CHR(10),  tSqlStatement;
        RAISE EXCEPTION '%',                SQLSTATE;
END;
$BODY$
LANGUAGE    plpgsql
SECURITY    DEFINER;

