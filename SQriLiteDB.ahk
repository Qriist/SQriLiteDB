#Requires AutoHotkey v2.0.0
;#include <Aris/Qriist/SqlarMultipleCiphers> ; github:Qriist/SqlarMultipleCiphers@v2.0.2+SqlarMultipleCiphers.ICU.7z --main *.*
#include <Aris/Qriist/Null> ; github:Qriist/Null@v1.0.0 --main Null.ahk
; ======================================================================================================================
; Function:         Class definitions as wrappers for SQLite3.dll to work with SQLite DBs.
; AHK version:      AHK 2.0.10 (U32/U64)
; Tested on:        Win 10 Pro (x64), SQLite 3.40.1 (x64)
; Version:          2.0.0/2023-01-05/just me    - Initial release for AHK 2.0
;                   2.0.1/2023-04-03/just me    - Added EnableLoadExtension() method
;                                               - Added LoadExtension() method
;                   2.0.2/2023-07-24/just me    - Added _ErrStr() method
;                                               - Fixed bug in _SetError() when the DB could not be opened
;                   2.0.3/2023-08-28/just me    - Fixed v2.1.2 related bug in Class _Prepared->Next() method.
;                   2.0.4/2023-08-31/just me    - Fixed possible naming conflicts with the global scope
;                   2.0.5/2023-09-08/just me    - Final fix for _Prepared->Next() method.
;                   2.0.6/2023-11-28/just me    - Fix for _Prepared->Bind() method.
; Remarks:          Names of "private" properties / methods are prefixed with an underscore,
;                   they must not be set / called by the script!
;
;                   SQLite3.dll file is assumed to be in the script's folder, otherwise you have to
;                   provide an INI-File SQriLiteDB.ini in the script's folder containing the path:
;                   [Main]
;                   DllPath=Path to SQLite3.dll
;
;                   Encoding of SQLite DBs is assumed to be UTF-8
;                   Minimum supported SQLite3.dll version is 3.6
;                   Download the current version of SQLite3.dll (and also SQlite3.exe) from www.sqlite.org
; ======================================================================================================================
; This software is provided 'as-is', without any express or implied warranty.
; In no event will the authors be held liable for any damages arising from the
; use of this software.
; ======================================================================================================================
; CLASS SQriLiteDB - SQriLiteDB main class
; ======================================================================================================================
Class SQriLiteDB {
   ; ===================================================================================================================
   ; CONSTRUCTOR __New
   ; ===================================================================================================================
   __New() {
      Local DLL, LibVersion, SQLiteDLL
      This._Path := ""                  ; Database path                                 (String)
      This._Handle := 0                 ; Database handle                               (Pointer)
      This._Stmts := Map()              ; Valid prepared statements                     (Map)
      If (SQriLiteDB._RefCount = 0) {
         SQLiteDLL := SQriLiteDB._SQLiteDLL
         If !FileExist(SQLiteDLL)
            If FileExist(A_ScriptDir . "\SQriLiteDB.ini") {
               SQLiteDLL := IniRead(A_ScriptDir . "\SQriLiteDB.ini", "Main", "DllPath", SQLiteDLL)
               SQriLiteDB._SQLiteDLL := SQLiteDLL
         } else {
            SQLiteDLL := this._findArisInstallDir("Qriist","SqlarMultipleCiphers") "\sqlite3.dll"
            If FileExist(SQLiteDLL)
               SQriLiteDB._SQLiteDLL := SQLiteDLL
         }
         Critical("On") ;ensure the dll load doesn't get interrupted
         If FileExist(SQriLiteDB._SQLiteDLL){
            oldWorkingDir := A_WorkingDir
            SplitPath(SQriLiteDB._SQLiteDLL,,&dir)
            SetWorkingDir(dir)
         }
         If !(DLL := DllCall("LoadLibrary", "Str", SQriLiteDB._SQLiteDLL, "UPtr")) {
            MsgBox("DLL " . SQLiteDLL . " does not exist!", "SQriLiteDB Error", 16)
            ExitApp
         }
         SetWorkingDir(oldWorkingDir)
         Critical("Off")
         LibVersion := StrGet(this.sqlite3_libversion(), "UTF-8")
         If (VerCompare(LibVersion, SQriLiteDB._MinVersion) < 0) {
            DllCall("FreeLibrary", "Ptr", DLL)
            MsgBox("Version " . LibVersion . " of SQLite3.dll is not supported!`n`n" .
                   "You can download the current version from www.sqlite.org!",
                   "SQriLiteDB ERROR", 16)
            ExitApp
         }
         SQriLiteDB.Version := LibVersion
      }
      SQriLiteDB._RefCount += 1
   }
   _findArisInstallDir(user,packageName){ ;dynamically finds a local versioned Aris installation
      If DirExist(A_ScriptDir "\lib\Aris\" user) ;"top level" install
         packageDir := A_ScriptDir "\lib\Aris\" user
      else if DirExist(A_ScriptDir "\..\lib\Aris\" user) ;script one level down
         packageDir := A_ScriptDir "\..\lib\Aris\" user
      else
         return ""
      loop files (packageDir "\" packageName "@*") , "D"{
         ;should end up with the latest installation
         ArisDir := packageDir "\" A_LoopFileName
      }
      return ArisDir
    }

   ; ===================================================================================================================
   ; DESTRUCTOR __Delete
   ; ===================================================================================================================
   __Delete() {
      Local DLL
      If (This._Handle)
         This.CloseDB()
      SQriLiteDB._RefCount -= 1
      If (SQriLiteDB._RefCount = 0) {
         If (DLL := DllCall("GetModuleHandle", "Str", SQriLiteDB._SQLiteDLL, "UPtr"))
            DllCall("FreeLibrary", "Ptr", DLL)
      }
   }
   ; ===================================================================================================================
   ; Properties
   ; ===================================================================================================================
    ErrorMsg := ""              ; Error message                           (String) 
    ErrorCode := 0              ; SQLite error code / ErrorLevel          (Variant)
    Changes := 0                ; Changes made by last call of Exec()     (Integer)
    SQL := ""                   ; Last executed SQL statement             (String)
   ; ===================================================================================================================
   ; METHOD OpenDB         Open a database
   ; Parameters:           DBPath      - Path of the database file
   ;                       Access      - Wanted access: "R"ead / "W"rite
   ;                       Create      - Create new database in write mode, if it doesn't exist
   ; Return values:        On success  - True
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; Remarks:              If DBPath is empty in write mode, a database called ":memory:" is created in memory
   ;                       and deletet on call of CloseDB.
   ; ===================================================================================================================
   OpenDB(DBPath, Access := "W", Create := True) {
      Static SQLITE_OPEN_READONLY  := 0x01 ; Database opened as read-only
      Static SQLITE_OPEN_READWRITE := 0x02 ; Database opened as read-write
      Static SQLITE_OPEN_CREATE    := 0x04 ; Database will be created if not exists
      Static MEMDB := ":memory:"
      Local Flags, HDB, RC, UTF8
      This.ErrorMsg := ""
      This.ErrorCode := 0
      HDB := 0
      If (DBPath = "")
         DBPath := MEMDB
      If (DBPath = This._Path) && (This._Handle)
         Return True
      If (This._Handle)
         Return This._SetError(0, "you must first close DB`n" . This._Path)
      Flags := 0
      Access := SubStr(Access, 1, 1)
      If (Access != "W") && (Access != "R")
         Access := "R"
      Flags := SQLITE_OPEN_READONLY
      If (Access = "W") {
         Flags := SQLITE_OPEN_READWRITE
         If (Create)
            Flags |= SQLITE_OPEN_CREATE
      }
      This._Path := DBPath
      UTF8 := This._StrToUTF8(DBPath)
      HDB := 0
      RC := this.sqlite3_open_v2(UTF8, &HDB, Flags)
      If (RC) {
         This._Path := ""
         Return This._SetError(RC, This._ErrStr(RC) . "`n" . DBPath)
      }
      This._Handle := HDB
      Return True
   }
   ; ===================================================================================================================
   ; METHOD CloseDB        Close database
   ; Parameters:           None
   ; Return values:        On success  - True
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   CloseDB() {
      Local Each, Stmt, RC
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := ""
      If !(This._Handle)
         Return True
      For Each, Stmt in This._Stmts
         this.sqlite3_finalize(Stmt)
      If (RC := this.sqlite3_close())
         Return This._SetError(RC)
      This._Path := ""
      This._Handle := ""
      This._Stmts := Map()
      Return True
   }

   ; ===================================================================================================================
   ; METHOD AttachDB       Add another database file to the current database connection
   ;                       http://www.sqlite.org/lang_attach.html
   ; Parameters:           DBPath      - Path of the database file
   ;                       DBAlias     - Database alias name used internally by SQLite
   ; Return values:        On success  - True
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   AttachDB(DBPath, DBAlias) {
      Return This.Exec("ATTACH DATABASE '" . DBPath . "' As " . DBAlias . ";")
   }
   ; ===================================================================================================================
   ; METHOD DetachDB       Detaches an additional database connection previously attached using AttachDB()
   ;                       http://www.sqlite.org/lang_detach.html
   ; Parameters:           DBAlias     - Database alias name used with AttachDB()
   ; Return values:        On success  - True
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   DetachDB(DBAlias) {
      Return This.Exec("DETACH DATABASE " . DBAlias . ";")
   }
   ; ===================================================================================================================
   ; METHOD Exec           Execute SQL statement
   ; Parameters:           SQL         - Valid SQL statement
   ;                       Callback    - Name of a callback function to invoke for each result row coming out
   ;                                     of the evaluated SQL statements.
   ;                                     The function must accept 4 parameters:
   ;                                     1: SQriLiteDB object
   ;                                     2: Number of columns
   ;                                     3: Pointer to an array of pointers to columns text
   ;                                     4: Pointer to an array of pointers to column names
   ;                                     The address of the current SQL string is passed in A_EventInfo.
   ;                                     If the callback function returns non-zero, DB.Exec() returns SQLITE_ABORT
   ;                                     without invoking the callback again and without running any subsequent
   ;                                     SQL statements.  
   ; Return values:        On success  - True, the number of changed rows is given in property Changes
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   Exec(SQL, Callback := "") {
      Local CBPtr, Err, RC, UTF8
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := SQL
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      CBPtr := 0
      Err := 0
      If (Type(Callback) = "Func") && (Callback.MinParams = 4)
         CBPtr := CallbackCreate(Callback, "C", 4)
      UTF8 := This._StrToUTF8(SQL)
      RC := this.sqlite3_exec(UTF8, CBPtr, ObjPtr(This), &Err)
      If (CBPtr)
         CallbackFree(CBPtr)
      If (RC) {
         This.ErrorMsg := StrGet(Err, "UTF-8")
         This.ErrorCode := RC
         this.sqlite3_free(Err)
         Return False
      }
      This.Changes := This._Changes()
      Return True
   }
   ; ===================================================================================================================
   ; METHOD GetTable       Get complete result for SELECT query
   ; Parameters:           SQL         - SQL SELECT statement
   ;                       ByRef TB    - Variable to store the result object (TB _Table)
   ;                       MaxResult   - Number of rows to return:
   ;                          0          Complete result (default)
   ;                         -1          Return only RowCount and ColumnCount
   ;                         -2          Return counters and array ColumnNames
   ;                          n          Return counters and ColumnNames and first n rows
   ; Return values:        On success  - True, TB contains the result object
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   GetTable(SQL, &TB, MaxResult := 0) {
      TB := ""
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := SQL
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      Local Names := ""
      Local Err := 0, GetRows := 0, RC := 0
      Local I := 0, Rows := Cols := 0
      Local Table := 0
      If !IsInteger(MaxResult)
         MaxResult := 0
      If (MaxResult < -2)
         MaxResult := 0
      Local UTF8 := This._StrToUTF8(SQL)
      RC := this.sqlite3_get_table(UTF8, &Table, &Rows, &Cols, &Err)
      If (RC) {
         This.ErrorMsg := StrGet(Err, "UTF-8")
         This.ErrorCode := RC
         this.sqlite3_free(Err)
         Return False
      }
      TB := SQriLiteDB._Table()
      TB.ColumnCount := Cols
      TB.RowCount := Rows
      If (MaxResult = -1) {
         this.sqlite3_free_table(Table)
         Return True
      }
      If (MaxResult = -2)
         GetRows := 0
      Else If (MaxResult > 0) && (MaxResult <= Rows)
         GetRows := MaxResult
      Else
         GetRows := Rows
      Local Offset := 0
      Names := []
      Names.Length := Cols
      Loop Cols {
         Names[A_Index] := StrGet(NumGet(Table + Offset, "UPtr"), "UTF-8")
         Offset += A_PtrSize
      }
      TB.ColumnNames := Names
      TB.HasNames := True
      TB.Rows.Length := GetRows
      Local ColArr
      Loop GetRows {
         ColArr := []
         ColArr.Length := Cols
         Loop Cols {
            ColArr[A_Index] := (Pointer := NumGet(Table + Offset, "UPtr")) ? StrGet(Pointer, "UTF-8") : ""
            Offset += A_PtrSize
         }
         TB.Rows[A_Index] := ColArr
      }
      If (GetRows)
         TB.HasRows := True
      this.sqlite3_free_table(Table)
      Return True
   }
   ; ===================================================================================================================
   ; Prepared statement 10:54 2019.07.05. by Dixtroy
   ;  DB := SQriLiteDB()
   ;  DB.OpenDB(DBFileName)
   ;  DB.Prepare 1 or more, just once
   ;  DB.Step 1 or more on prepared one, repeatable
   ;  DB.Finalize at the end
   ; ===================================================================================================================
   ; ===================================================================================================================
   ; METHOD Prepare        Prepare database table for further actions.
   ; Parameters:           SQL         - SQL statement to be compiled
   ;                       ByRef ST    - Variable to store the statement object (Class _Statement)
   ; Return values:        On success  - True, ST contains the statement object
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; Remarks:              You have to pass one ? for each column you want to assign a value later.
   ; ===================================================================================================================
   Prepare(SQL, &ST) {
      Local ColumnCount, ColumnNames, Pointer, RC
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := SQL
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      Local Stmt := 0
      Local UTF8 := This._StrToUTF8(SQL)
      RC := this.sqlite3_prepare_v2(UTF8, &Stmt)
      If (RC)
         Return This._SetError(RC)
      ColumnNames := []
      ColumnCount := this.sqlite3_column_count(Stmt)
      If (ColumnCount > 0) {
         ColumnNames.Length := ColumnCount
         Loop ColumnCount {
            Pointer := this.sqlite3_column_name(Stmt, A_Index - 1)
            ColumnNames[A_Index] := StrGet(Pointer, "UTF-8")
         }
      }
		ST := SQriLiteDB._Prepared()
      ST.ColumnCount := ColumnCount
      ST.ColumnNames := ColumnNames
      ST.ParamCount := this.sqlite3_bind_parameter_count(Stmt)
      ST._Handle := Stmt
      ST._DB := This
      This._Stmts[Stmt] := Stmt
      Return True
   }
   ; ===================================================================================================================
   ; METHOD CreateScalarFunc  Create a scalar application defined function
   ; Parameters:              Name  -  the name of the function
   ;                          Args  -  the number of arguments that the SQL function takes
   ;                          Func  -  a pointer to AHK functions that implement the SQL function
   ;                          Enc   -  specifies what text encoding this SQL function prefers for its parameters
   ;                          Param -  an arbitrary pointer accessible within the funtion with sqlite3_user_data()
   ; Return values:           On success  - True
   ;                          On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; Documentation:           www.sqlite.org/c3ref/create_function.html
   ; ===================================================================================================================
   CreateScalarFunc(Name, Args, Func, Enc := 0x0801, Param := 0) {
      ; SQLITE_DETERMINISTIC = 0x0800 - the function will always return the same result given the same inputs
      ;                                 within a single SQL statement
      ; SQLITE_UTF8 = 0x0001
      This.ErrorMsg := ""
      This.ErrorCode := 0
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      Local RC := this.sqlite3_create_function(Name, Args, Enc, Param, Func)
      Return (RC) ? This._SetError(RC) : True
   }
   ; ===================================================================================================================
   ; METHOD EnableLoadExtension  Enable or disable the sqlite3_load_extension() interface
   ; Parameters:                 Enable (1 = enable, 0 = disable)
   ; Return values:              On success  - True
   ;                             On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; Documentation:              www.sqlite.org/c3ref/enable_load_extension.html
   ;                             #define SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION 1005 /* int int* */
   ; ===================================================================================================================
   EnableLoadExtension(Enable := 1) {
      Local RC := this.sqlite3_db_config(1005,!!Enable)
      Return (RC) ? This._SetError(RC) : True
   }
   ; ===================================================================================================================
   ; METHOD LoadExtension     Enable or disable the sqlite3_load_extension() interface
   ; Parameters:              File - Name of the shared library containing extension
   ;                          Proc - Name of the entry point. Derived from File if omitted.
   ; Return values:           On success  - True
   ;                          On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; Documentation:           https://www.sqlite.org/c3ref/load_extension.html
   ; ===================================================================================================================
   LoadExtension(File, Proc?) {
      Local RC := IsSet(Proc) ? this.sqlite3_load_extension(File, Proc)
                              : this.sqlite3_load_extension(File, 0)
      Return (RC) ? This._SetError(RC) : True
   }
   ; ===================================================================================================================
   ; METHOD LastInsertRowID   Get the ROWID of the last inserted row
   ; Parameters:              ByRef RowID - Variable to store the ROWID
   ; Return values:           On success  - True, RowID contains the ROWID
   ;                          On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   LastInsertRowID(&RowID) {
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := ""
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      RowID := this.sqlite3_last_insert_rowid()
      Return True
   }
   ; ===================================================================================================================
   ; METHOD TotalChanges   Get the number of changed rows since connecting to the database
   ; Parameters:           ByRef Rows  - Variable to store the number of rows
   ; Return values:        On success  - True, Rows contains the number of rows
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   TotalChanges(&Rows) {
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := ""
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      Rows := this.sqlite3_total_changes()
      Return True
   }
   ; ===================================================================================================================
   ; METHOD SetTimeout     Set the timeout to wait before SQLITE_BUSY or SQLITE_IOERR_BLOCKED is returned,
   ;                       when a table is locked.
   ; Parameters:           TimeOut     - Time to wait in milliseconds
   ; Return values:        On success  - True
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   SetTimeout(Timeout := 1000) {
      Local RC
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := ""
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      If !IsInteger(Timeout)
         Timeout := 1000
      If (RC := this.sqlite3_busy_timeout(Timeout))
         Return This._SetError(RC)
      Return True
   }
   ; ===================================================================================================================
   ; METHOD EscapeStr      Escapes special characters in a string to be used as field content
   ; Parameters:           Str         - String to be escaped
   ;                       Quote       - Add single quotes around the outside of the total string (True / False)
   ; Return values:        On success  - True
   ;                       On failure  - False, ErrorMsg / ErrorCode contain additional information
   ; ===================================================================================================================
   EscapeStr(&Str, Quote := True) {
      This.ErrorMsg := ""
      This.ErrorCode := 0
      This.SQL := ""
      If !(This._Handle)
         Return This._SetError(0, "Invalid database handle!")
      If IsNumber(Str)
         Return True
      Local OP := Buffer(16, 0)
      StrPut(Quote ? "%Q" : "%q", OP, "UTF-8")
      Local UTF8 := This._StrToUTF8(Str)
      Local Ptr := this.sqlite3_mprintf(OP, UTF8)
      Str := StrGet(Ptr, "UTF-8")
      this.sqlite3_free(Ptr)
      Return True
   }
   ; ===================================================================================================================
   ; METHOD ExtErrCode     Gets the extended result code in case of errors.
   ; Parameters:           None.
   ; Return values:        On success  - Extended result code
   ;                       On failure  - 0
   ; Remarks:              Extended result code list -> https://www.sqlite.org/rescode.html#extrc
   ; ===================================================================================================================
   ExtErrCode() {
      If !(This._Handle)
         Return 0
      Return this.sqlite3_extended_errcode()
   }
   ; ===================================================================================================================
   ; PRIVATE _Changes
   ; ===================================================================================================================
   _Changes() {
      Return this.sqlite3_changes()
   }
   ; ===================================================================================================================
   ; PRIVATE _ErrMsg
   ; ===================================================================================================================
   _ErrMsg() {
      Local RC
      If (RC := this.sqlite3_errmsg())
         Return StrGet(RC, "UTF-8")
      Return ""
   }
   ; ===================================================================================================================
   ; PRIVATE _ErrCode
   ; ===================================================================================================================
   _ErrCode() {
      Return this.sqlite3_errcode()
   }
   ; ===================================================================================================================
   ; PRIVATE _ErrStr
   ; ===================================================================================================================
   _ErrStr(ErrCode) {
      Return StrGet(this.sqlite3_errstr(ErrCode), "UTF-8")
   }
   ; ===================================================================================================================
   ; PRIVATE _SetError
   ; ===================================================================================================================
   _SetError(RC, Msg?) {
      This.ErrorMsg := IsSet(Msg) ? Msg : This._ErrMsg()
      This.ErrorCode := RC
      Return False
   }
   ; ===================================================================================================================
   ; PRIVATE _StrToUTF8
   ; ===================================================================================================================
   _StrToUTF8(Str) {
      Local UTF8 := Buffer(StrPut(Str, "UTF-8"), 0)
      StrPut(Str, UTF8, "UTF-8")
      Return UTF8
   }
   ; ===================================================================================================================
   ; PRIVATE _Returncode
   ; ===================================================================================================================
   _ReturnCode(RC) {
      Static RCODE := {SQLITE_OK:           0, ; Successful result
                       SQLITE_ERROR:        1, ; SQL error or missing database
                       SQLITE_INTERNAL:     2, ; NOT USED. Internal logic error in SQLite
                       SQLITE_PERM:         3, ; Access permission denied
                       SQLITE_ABORT:        4, ; Callback routine requested an abort
                       SQLITE_BUSY:         5, ; The database file is locked
                       SQLITE_LOCKED:       6, ; A table in the database is locked
                       SQLITE_NOMEM:        7, ; A malloc() failed
                       SQLITE_READONLY:     8, ; Attempt to write a readonly database
                       SQLITE_INTERRUPT:    9, ; Operation terminated by sqlite3_interrupt()
                       SQLITE_IOERR:       10, ; Some kind of disk I/O error occurred
                       SQLITE_CORRUPT:     11, ; The database disk image is malformed
                       SQLITE_NOTFOUND:    12, ; NOT USED. Table or record not found
                       SQLITE_FULL:        13, ; Insertion failed because database is full
                       SQLITE_CANTOPEN:    14, ; Unable to open the database file
                       SQLITE_PROTOCOL:    15, ; NOT USED. Database lock protocol error
                       SQLITE_EMPTY:       16, ; Database is empty
                       SQLITE_SCHEMA:      17, ; The database schema changed
                       SQLITE_TOOBIG:      18, ; String or BLOB exceeds size limit
                       SQLITE_CONSTRAINT:  19, ; Abort due to constraint violation
                       SQLITE_MISMATCH:    20, ; Data type mismatch
                       SQLITE_MISUSE:      21, ; Library used incorrectly
                       SQLITE_NOLFS:       22, ; Uses OS features not supported on host
                       SQLITE_AUTH:        23, ; Authorization denied
                       SQLITE_FORMAT:      24, ; Auxiliary database format error
                       SQLITE_RANGE:       25, ; 2nd parameter to sqlite3_bind out of range
                       SQLITE_NOTADB:      26, ; File opened that is not a database file
                       SQLITE_ROW:        100, ; sqlite3_step() has another row ready
                       SQLITE_DONE:       101} ; sqlite3_step() has finished executing
      Return RCODE.HasOwnProp(RC) ? RCODE.%RC% : ""
   }
   ; +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
   ; +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
   ; PRIVATE Properties ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
   ; +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
   ; +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
   Static Version := ""
   Static _SQLiteDLL := A_ScriptDir . "\SQLite3.dll"
   Static _RefCount := 0
   Static _MinVersion := "3.6"
   ; ===================================================================================================================
   ; CLASS _Table
   ; Object returned from method GetTable()
   ; _Table is an independent object and does not need SQLite after creation at all.
   ; ===================================================================================================================
   Class _Table {
      ; ----------------------------------------------------------------------------------------------------------------
      ; CONSTRUCTOR  Create instance variables
      ; ----------------------------------------------------------------------------------------------------------------
      __New() {
          This.ColumnCount := 0          ; Number of columns in the result table         (Integer)
          This.RowCount := 0             ; Number of rows in the result table            (Integer)
          This.ColumnNames := []         ; Names of columns in the result table          (Array)
          This.Rows := []                ; Rows of the result table                      (Array of Arrays)
          This.HasNames := False         ; Does var ColumnNames contain names?           (Bool)
          This.HasRows := False          ; Does var Rows contain rows?                   (Bool)
          This._CurrentRow := 0          ; Row index of last returned row                (Integer)
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD GetRow      Get row for RowIndex
      ; Parameters:        RowIndex    - Index of the row to retrieve, the index of the first row is 1
      ;                    ByRef Row   - Variable to pass out the row array
      ; Return values:     On failure  - False
      ;                    On success  - True, Row contains a valid array
      ; Remarks:           _CurrentRow is set to RowIndex, so a subsequent call of NextRow() will return the
      ;                    following row.
      ; ----------------------------------------------------------------------------------------------------------------
      GetRow(RowIndex, &Row) {
         Row := ""
         If (RowIndex < 1 || RowIndex > This.RowCount)
            Return False
         If !This.Rows.Has(RowIndex)
            Return False
         Row := This.Rows[RowIndex]
         This._CurrentRow := RowIndex
         Return True
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD Next        Get next row depending on _CurrentRow
      ; Parameters:        ByRef Row   - Variable to pass out the row array
      ; Return values:     On failure  - False, -1 for EOR (end of rows)
      ;                    On success  - True, Row contains a valid array
      ; ----------------------------------------------------------------------------------------------------------------
      Next(&Row) {
         Row := ""
         If (This._CurrentRow >= This.RowCount)
            Return -1
         This._CurrentRow += 1
         If !This.Rows.Has(This._CurrentRow)
            Return False
         Row := This.Rows[This._CurrentRow]
         Return True
      }

      ; ----------------------------------------------------------------------------------------------------------------
		; METHOD NextNamed   Get next row depending on _CurrentRow; same as Next() but returns a Map with column names
		; Parameters:        ByRef Row   - Variable to pass out the row Map 
		; Return values:     On failure  - False, -1 for EOR (end of rows)
		;                    On success  - True, Row contains a valid Map 
		; ----------------------------------------------------------------------------------------------------------------
		NextNamed(&Row) {
         Row := ""
         If (This._CurrentRow >= This.RowCount)
            Return -1
         This._CurrentRow += 1
         If !This.Rows.Has(This._CurrentRow)
            Return False
         Row := Map()
         for k,v in this.Rows[This._CurrentRow] {
            Row[This.ColumnNames[k]] := v
         }
         Return True
      }
		
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD Reset       Reset _CurrentRow to zero
      ; Parameters:        None
      ; Return value:      True
      ; ----------------------------------------------------------------------------------------------------------------
      Reset() {
         This._CurrentRow := 0
         Return True
      }
   }
   ; ===================================================================================================================
   ; CLASS _Prepared
   ; Object returned from method Prepare()
   ; The life-cycle of a prepared statement object usually goes like this:
   ; 1. Create the prepared statement object (PST) by calling DB.Prepare().
   ; 2. Bind values to parameters using the PST.Bind() method of the statement object if needed.
   ; 3. Run the SQL by calling PST.Step() one or more times.
   ; 4. Reset the prepared statement using PTS.Reset() then go back to step 2. Do this zero or more times.
   ; 5. Destroy the object using PST.Free().
   ; The lifetime of a prepared statement depends on the lifetime of the related SQriLiteDB object.
   ; The rows (records) of the result of a query statement can be fetched sequentially by successive calls of
   ; PST.Step(&Row)
   ; ===================================================================================================================
   Class _Prepared {
      ; ----------------------------------------------------------------------------------------------------------------
      ; CONSTRUCTOR  Create instance variables
      ; ----------------------------------------------------------------------------------------------------------------
      __New() {
         This.ColumnCount := 0         ; Number of columns in the result               (Integer)
         This.ColumnNames := []        ; Names of columns in the result                (Array)
         This.CurrentStep := 0         ; Index of current step                         (Integer)
         This.ErrorMsg := ""           ; Last error message                            (String)
         This.ErrorCode := 0           ; Last SQLite error code / ErrorLevel           (Variant)
         This._Handle := 0             ; Query handle                                  (Pointer)
         This._DB := {}                ; SQriLiteDB object                               (Object)
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; DESTRUCTOR   Clear instance variables
      ; ----------------------------------------------------------------------------------------------------------------
      __Delete() {
         If This.HasOwnProp("_Handle") && (This._Handle != 0)
            This.Free()
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD Bind        Bind values to SQL parameters.
      ; Parameters:        Params      -  Array of SQL parameters.
      ;                                   The index within the array determines the index of the SQL parameter.
      ;                                   Each array element must be an associative array with one key/value pair:
      ;                                      Key   = one of the types defined below in Types
      ;                                      Value = type dependend value of the parameter
      ; Return values:     On success  - True
      ;                    On failure  - False, ErrorMsg / ErrorCode contain additional information
      ; ----------------------------------------------------------------------------------------------------------------
      Bind(Params) {
         Static Types := {Blob: 1, Double: 1, Int: 1, Int64: 1, Null: 1, Text: 1}
         Local Index, Param, ParamType, RC, UTF8, Value
         This.ErrorMsg := ""
         This.ErrorCode := 0
         If !(This._Handle) {
            This.ErrorMsg := "Invalid statement handle!"
            Return False
         }
         For Index, Param In Params {
            If (Index < 1) || (Index > This.ParamCount)
               Return This._SetError(0, "Invalid parameter index: " . Index . "!")
            For ParamType, Value In Param {
               If !Types.HasOwnProp(ParamType)
                  Return This._SetError(0, "Invalid parameter type " . ParamType . " at index " Index . "!")
               Switch ParamType {
                  Case "Blob":
                     ; Value = Buffer object
                     If !(ParamType(Value) = "Buffer")
                        Return This._SetError(0, "Invalid blob object at index " . Index . "!")
                     ; Let SQLite always create a copy of the BLOB
                     RC := this._DB.sqlite3_bind_blob(this._Handle, Index, Value)
                     If (RC)
                        Return This._SetError(RC)
                  Case "Double":
                     ; Value = double value
                     If !IsFloat(Value)
                        Return This._SetError(0, "Invalid value for double at index " . Index . "!")
                     RC := this._DB.sqlite3_bind_double(this._Handle, Index, Value)
                     If (RC)
                        Return This._SetError(RC)
                  Case "Int":
                     ; Value = integer value
                     If !IsInteger(Value)
                        Return This._SetError(0, "Invalid value for int at index " . Index . "!")
                     RC := this._DB.sqlite3_bind_int(this._Handle, Index, Value)
                     If (RC)
                        Return This._SetError(RC)
                  Case "Int64":
                     ; Value = integer value
                     If !IsInteger(Value)
                        Return This._SetError(0, "Invalid value for int64 at index " . Index . "!")
                     RC := this._DB.sqlite3_bind_int64(this._Handle, Index, Value)
                     If (RC)
                        Return This._SetError(RC)
                  Case "Null":
                     RC := this._DB.sqlite3_bind_null(this._Handle, Index)
                     If (RC)
                        Return This._SetError(RC)
                  Case "Text":
                     ; Value = zero-terminated string
                     UTF8 := This._DB._StrToUTF8(Value)
                     ; Let SQLite always create a copy of the text
                     RC := this._DB.sqlite3_bind_text(this._Handle, Index, UTF8)
                     If (RC)
                        Return This._SetError(RC)
               }
               Break
            }
         }
         Return True
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD Step        Execute the statement and get next row of the query result if available.
      ; Parameters:        Row         - Optional: VarRef to store the row array
      ; Return values:     On success  - True, Row contains the row array
      ;                    On failure  - False, ErrorMsg / ErrorCode contain additional information
      ;                                  -1 for EOR (end of records)
      ; ----------------------------------------------------------------------------------------------------------------
      Step(Row?) { ; !!!!! Note: If Row is not omitted is must be a VarRef !!!!!
         Static SQLITE_INTEGER := 1, SQLITE_FLOAT := 2, SQLITE_BLOB := 4, SQLITE_NULL := 5
         Static EOR := -1
         Local Blob, BlobPtr, BlobSize, Column, ColumnType, RC, Res, Value
         If IsSet(Row) && !(Row Is VarRef)
            Throw TypeError("Parameter #1 requires a variable reference, but received a" .
                            (Type(Row) ~= "i)^[aeiou]" ? "n " : " ") . Type(Row) ".", -1, Row)
         This.ErrorMsg := ""
         This.ErrorCode := 0
         If !(This._Handle)
            Return This._SetError(0, "Invalid query handle!")
         RC := this._DB.sqlite3_step(This._Handle)
         If (RC = This._DB._ReturnCode("SQLITE_DONE"))
            Return (This._SetError(RC, "EOR") | EOR)
         If (RC != This._DB._ReturnCode("SQLITE_ROW"))
            Return This._SetError(RC)
         This.CurrentStep += 1
         If !IsSet(Row)
            Return True
         Res := Map()
         RC := this._DB.sqlite3_data_count()
         If (RC < 1)
            Return True
         Res.Length := RC
         Loop RC {
            Column := A_Index - 1
            ColumnType := this._DB.sqlite3_column_type(this._Handle, Column)
            Name := StrGet(this._DB.sqlite3_column_name(this._Handle, Column),"UTF-8")
            Switch ColumnType {
               Case SQLITE_BLOB:
                  BlobPtr := this._DB.sqlite3_column_blob(this._Handle, Column)
                  BlobSize := this._DB.sqlite3_column_bytes(this._Handle, Column)
                  If (BlobPtr = 0) || (BlobSize = 0)
                     Res[Name] := ""
                  Else {
                     Blob := Buffer(BlobSize)
                     DllCall("Kernel32.dll\RtlMoveMemory", "Ptr", Blob, "Ptr", BlobPtr, "Ptr", BlobSize)
                     Res[Name] := Blob
                  }
               Case SQLITE_INTEGER:
                  Value := this._DB.sqlite3_column_int64(this._Handle, Column)
                  Res[Name] := Value
               Case SQLITE_FLOAT:
                  Value := this._DB.sqlite3_column_double(this._Handle, Column)
                  Res[Name] := Value
               Case SQLITE_NULL:
                  Res[Name] := Null()
               Default:
                  Value := this._DB.sqlite3_column_text(this._Handle, Column)
                  Res[Name] := StrGet(Value, "UTF-8")
            }
         }
         %Row% := Res
         Return True
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD Next        Alternative name for Step().
      ; Parameters:        Row         - Optional: VarRef to store the row array
      ; ----------------------------------------------------------------------------------------------------------------
      Next(Row?) { ; !!!!! Note: If Row is not omitted is must be a VarRef !!!!!
         If !IsSet(Row)
            Return This.Step()
         If Row Is VarRef
            Return This.Step(Row)
         Throw TypeError("Parameter #1 requires a variable reference, but received a" .
                         (Type(Row) ~= "i)^[aeiou]" ? "n " : " ") . Type(Row) ".", -1, Row)
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD Reset       Reset result pointer of the prepared statement.
      ; Parameters:        ClearBindings  - Clear bound SQL parameter values (True/False)
      ; Return values:     On success     - True
      ;                    On failure     - False, ErrorMsg / ErrorCode contain additional information
      ; Remarks:           After a call of this method you can access the query result via Next() again.
      ; ----------------------------------------------------------------------------------------------------------------
      Reset(ClearBindings := True) {
         Local RC
         This.ErrorMsg := ""
         This.ErrorCode := 0
         If !(This._Handle)
            Return This._SetError(0, "Invalid query handle!")
         If (RC := this._DB.sqlite3_reset(this._Handle))
            Return This._SetError(RC)
         If (ClearBindings) && (RC := this._DB.sqlite3_clear_bindings())
            Return This._SetError(RC)
         This.CurrentStep := 0
         Return True
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD Free        Free the prepared statement.
      ; Parameters:        None
      ; Return values:     On success  - True
      ;                    On failure  - False, ErrorMsg / ErrorCode contain additional information
      ; Remarks:           After the call of this method further access on the query result is impossible.
      ; ----------------------------------------------------------------------------------------------------------------
      Free() {
         Local RC
         This.ErrorMsg := ""
         This.ErrorCode := 0
         If !(This._Handle)
            Return True
         If (RC := this._DB.sqlite3_finalize(this._Handle))
            Return This._SetError(RC)
         This._DB._Stmts.Delete(This._Handle)
         This._Handle := 0
         This._DB := 0
         Return True
      }
      ; ----------------------------------------------------------------------------------------------------------------
      ; METHOD _SetError   Internally used for error handling
      ; Parameters:        RC - SQLite error code
      ;                    Msg - error message (optional), if omitted the SQLite error text will be set
      ; ----------------------------------------------------------------------------------------------------------------
      _SetError(RC, Msg?) {
         This.ErrorMsg := IsSet(Msg) ? Msg : This._DB._ErrMsg()
         This.ErrorCode := RC
         Return False
      }
   }
   sqlite3_aggregate_context(Context, nBytes) { ;untested https://sqlite.org/c3ref/aggregate_context.html
      static sqlite3_aggregate_context := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_aggregate_context")
      return DllCall(sqlite3_aggregate_context
         , "Ptr", Context
         , "Int", nBytes
         , "Cdecl UPtr")
   }
   sqlite3_auto_extension(xEntryPoint) {  ;untested   https://sqlite.org/c3ref/auto_extension.html
      static sqlite3_auto_extension := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_auto_extension")
      return DllCall(sqlite3_auto_extension
         , "Ptr", xEntryPoint
         , "Cdecl Int")
   }
   sqlite3_autovacuum_pages(db, Callback, Data, FreeFunc) { ;untested   https://sqlite.org/c3ref/autovacuum_pages.html
      static sqlite3_autovacuum_pages := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_autovacuum_pages")
      return DllCall(sqlite3_autovacuum_pages
         , "Ptr", db
         , "Ptr", Callback
         , "Ptr", Data
         , "Ptr", FreeFunc
         , "Cdecl Int")
   }
   sqlite3_backup_init(pDest, zDestName, pSource, zSourceName) {   ;untested   https://sqlite.org/c3ref/backup_finish.html
      static sqlite3_backup_init := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_backup_init")
      return DllCall(sqlite3_backup_init
         , "Ptr", pDest
         , "AStr", zDestName
         , "Ptr", pSource
         , "AStr", zSourceName
         , "Cdecl UPtr")
   }
   sqlite3_backup_step(backup, nPage) {   ;untested   https://sqlite.org/c3ref/backup_finish.html
      static sqlite3_backup_step := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_backup_step")
      return DllCall(sqlite3_backup_step
         , "Ptr", backup
         , "Int", nPage
         , "Cdecl Int")
   }
   sqlite3_backup_finish(backup) {   ;untested   https://sqlite.org/c3ref/backup_finish.html
      static sqlite3_backup_finish := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_backup_finish")
      return DllCall(sqlite3_backup_finish
         , "Ptr", backup
         , "Cdecl Int")
   }
   sqlite3_backup_remaining(backup) {   ;untested   https://sqlite.org/c3ref/backup_finish.html
      static sqlite3_backup_remaining := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_backup_remaining")
      return DllCall(sqlite3_backup_remaining
         , "Ptr", backup
         , "Cdecl Int")
   }
   sqlite3_backup_pagecount(backup) {   ;untested   https://sqlite.org/c3ref/backup_finish.html
      static sqlite3_backup_pagecount := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_backup_pagecount")
      return DllCall(sqlite3_backup_pagecount
         , "Ptr", backup
         , "Cdecl Int")
   }
   sqlite3_bind_blob(stmt, Index, Value, Destructor := -1) {   ;https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_blob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_blob")
      return DllCall(sqlite3_bind_blob
         , "Ptr", stmt
         , "Int", Index
         , "Ptr", Value
         , "Int", Value.Size
         , "Ptr", Destructor
         , "Cdecl Int")
   }
   sqlite3_bind_blob64(stmt, Index, Value, Destructor := -1) {   ;untested   https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_blob64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_blob64")
      return DllCall(sqlite3_bind_blob64
         , "Ptr", stmt
         , "Int", Index
         , "Ptr", Value
         , "Int64", Value.Size
         , "Ptr", Destructor
         , "Cdecl Int")
   }
   sqlite3_bind_double(stmt, Index, Value) {   ;https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_double := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_double")
      return DllCall(sqlite3_bind_double
         , "Ptr", stmt,
         , "Int", Index
         , "Double", Value
         , "Cdecl Int")
   }
   sqlite3_bind_int(stmt, Index, Value) {   ;https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_int := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_int")
      return DllCall(sqlite3_bind_int
         , "Ptr", stmt,
         , "Int", Index
         , "Int", Value
         , "Cdecl Int")
   }
   sqlite3_bind_int64(stmt, Index, Value) {  ;https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_int64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_int64")
      return DllCall(sqlite3_bind_int64
         , "Ptr", stmt
         , "Int", Index
         , "Int64", Value
         , "Cdecl Int")
   }
   sqlite3_bind_null(stmt, Index) { ;https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_null := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_null")
      return DllCall(sqlite3_bind_null
         , "Ptr", stmt,
         , "Int", Index
         , "Cdecl Int")
   }
   sqlite3_bind_parameter_count(Stmt) {   ;https://sqlite.org/c3ref/bind_parameter_count.html
      static sqlite3_bind_parameter_count := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_parameter_count")
      return DllCall(sqlite3_bind_parameter_count
         , "Ptr", Stmt
         , "Cdecl Int")
   }
   sqlite3_bind_parameter_index(stmt, zName) {  ;untested   https://sqlite.org/c3ref/bind_parameter_index.html
      static sqlite3_bind_parameter_index := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_parameter_index")
      return DllCall(sqlite3_bind_parameter_index
         , "Ptr", stmt
         , "AStr", zName
         , "Cdecl Int")
   }
   sqlite3_bind_parameter_name(stmt, Index) {   ;untested   https://sqlite.org/c3ref/bind_parameter_name.html
      static sqlite3_bind_parameter_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_parameter_name")
      return DllCall(sqlite3_bind_parameter_name
         , "Ptr", stmt
         , "Int", Index
         , "Cdecl UPtr")
   }
   sqlite3_bind_pointer(stmt, Index, Pointer, typeName, destructor := -1) {   ;untested   https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_pointer := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_pointer")
      return DllCall(sqlite3_bind_pointer
         , "Ptr", stmt
         , "Int", Index
         , "Ptr", Pointer
         , "AStr", typeName
         , "Ptr", destructor
         , "Cdecl Int")
   }
   sqlite3_bind_text(stmt, Index, Value) { ;https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_text := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_text")
      return DllCall(sqlite3_bind_text
         , "Ptr", stmt
         , "Int", Index
         , "Ptr", Value
         , "Int", -1
         , "Ptr", -1
         , "Cdecl Int")
   }
   sqlite3_bind_text16(stmt, Index, Value) { ;https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_text16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_text16")
      return DllCall(sqlite3_bind_text16
         , "Ptr", stmt
         , "Int", Index
         , "Ptr", Value
         , "Int", -1
         , "Ptr", -1
         , "Cdecl Int")
   }
   sqlite3_bind_text64(stmt, Index, Value, destructor := -1, encoding := 1) {   ;untested   https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_text64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_text64")
      return DllCall(sqlite3_bind_text64
         , "Ptr", stmt
         , "Int", Index
         , "AStr", Value
         , "Int64", Value.Size
         , "Ptr", destructor
         , "Int", encoding
         , "Cdecl Int")
   }
   sqlite3_bind_value(stmt, Index, valuePtr) {  ;untested   https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_value := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_value")
      return DllCall(sqlite3_bind_value
         , "Ptr", stmt
         , "Int", Index
         , "Ptr", valuePtr
         , "Cdecl Int")
   }
   sqlite3_bind_zeroblob(stmt, Index, n) {   ;untested   https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_zeroblob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_zeroblob")
      return DllCall(sqlite3_bind_zeroblob
         , "Ptr", stmt
         , "Int", Index
         , "Int", n
         , "Cdecl Int")
   }

   sqlite3_bind_zeroblob64(stmt, Index, n) {   ;untested   https://sqlite.org/c3ref/bind_blob.html
      static sqlite3_bind_zeroblob64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_bind_zeroblob64")
      return DllCall(sqlite3_bind_zeroblob64
         , "Ptr", stmt
         , "Int", Index
         , "Int64", n
         , "Cdecl Int")
   }
   sqlite3_blob_bytes(blob) { ;untested   https://sqlite.org/c3ref/blob_bytes.html
      static sqlite3_blob_bytes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_blob_bytes")
      return DllCall(sqlite3_blob_bytes
         , "Ptr", blob
         , "Cdecl Int")
   }
   sqlite3_blob_close(blob) { ;untested   https://sqlite.org/c3ref/blob_close.html
      static sqlite3_blob_close := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_blob_close")
      return DllCall(sqlite3_blob_close
         , "Ptr", blob
         , "Cdecl Int")
   }
   sqlite3_blob_open(db, zDb, zTable, zColumn, iRow, flags, ppBlob) {   ;untested   https://sqlite.org/c3ref/blob_open.html
      static sqlite3_blob_open := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_blob_open")
      return DllCall(sqlite3_blob_open
         , "Ptr", db
         , "AStr", zDb
         , "AStr", zTable
         , "AStr", zColumn
         , "Int64", iRow
         , "Int", flags
         , "UPtrP", &ppBlob
         , "Cdecl Int")
   }
   sqlite3_blob_read(blob, Z, N, iOffset) {  ;untested   https://sqlite.org/c3ref/blob_read.html
      static sqlite3_blob_read := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_blob_read")
      return DllCall(sqlite3_blob_read
         , "Ptr", blob
         , "Ptr", Z
         , "Int", N
         , "Int", iOffset
         , "Cdecl Int")
   }
   sqlite3_blob_reopen(blob, iRow) {   ;untested   https://sqlite.org/c3ref/blob_reopen.html
      static sqlite3_blob_reopen := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_blob_reopen")
      return DllCall(sqlite3_blob_reopen
         , "Ptr", blob
         , "Int64", iRow
         , "Cdecl Int")
   }
   sqlite3_blob_write(blob, z, n, iOffset) { ;untested   https://sqlite.org/c3ref/blob_write.html
      static sqlite3_blob_write := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_blob_write")
      return DllCall(sqlite3_blob_write
         , "Ptr", blob
         , "Ptr", z
         , "Int", n
         , "Int", iOffset
         , "Cdecl Int")
   }
   sqlite3_busy_handler(db, callback, userData) {  ;untested   https://sqlite.org/c3ref/busy_handler.html
      static sqlite3_busy_handler := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_busy_handler")
      return DllCall(sqlite3_busy_handler
         , "Ptr", db
         , "Ptr", callback
         , "Ptr", userData
         , "Cdecl Int")
   }
   sqlite3_busy_timeout(Timeout) {  ;untested   https://sqlite.org/c3ref/busy_timeout.html
      static sqlite3_busy_timeout := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_busy_timeout")
      return DllCall(sqlite3_busy_timeout
         , "Ptr", this._Handle
         , "Int", Timeout
         , "Cdecl Int")
   }
   sqlite3_cancel_auto_extension(xEntryPoint) { ;untested   https://sqlite.org/c3ref/cancel_auto_extension.html
      static sqlite3_cancel_auto_extension := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_cancel_auto_extension")
      return DllCall(sqlite3_cancel_auto_extension
         , "Ptr", xEntryPoint
         , "Cdecl Int")
   }

   sqlite3_changes() {  ;https://sqlite.org/c3ref/changes.html
      static sqlite3_changes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_changes")
      return DllCall(sqlite3_changes
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_changes64() {   ;untested   https://sqlite.org/c3ref/changes.html
      static sqlite3_changes64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_changes64")
      return DllCall(sqlite3_changes64
         , "Ptr", this._Handle
         , "Cdecl Int64")
   }
   sqlite3_clear_bindings() { ;untested   https://sqlite.org/c3ref/clear_bindings.html
      static sqlite3_clear_bindings := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_clear_bindings")
      return DllCall(sqlite3_clear_bindings
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_close() { ;https://sqlite.org/c3ref/close.html
      static sqlite3_close := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_close")
      return DllCall(sqlite3_close
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_close_v2() { ;untested   https://sqlite.org/c3ref/close.html
      static sqlite3_close_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_close_v2")
      return DllCall(sqlite3_close_v2
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_collation_needed(pArg, xCollNeeded) {  ;untested   https://sqlite.org/c3ref/collation_needed.html
      static sqlite3_collation_needed := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_collation_needed")
      return DllCall(sqlite3_collation_needed
         , "Ptr", this._Handle
         , "Ptr", pArg
         , "Ptr", xCollNeeded
         , "Cdecl Int")
   }
   sqlite3_collation_needed16(pArg, xCollNeeded) {   ;untested   https://sqlite.org/c3ref/collation_needed.html
      static sqlite3_collation_needed16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_collation_needed16")
      return DllCall(sqlite3_collation_needed16
         , "Ptr", this._Handle
         , "Ptr", pArg
         , "Ptr", xCollNeeded
         , "Cdecl Int")
   }
   sqlite3_column_blob(stmt, Column) { 
      static sqlite3_column_blob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_blob")
      return DllCall(sqlite3_column_blob
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_bytes(stmt, Column) {
      static sqlite3_column_bytes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_bytes")
      return DllCall(sqlite3_column_bytes
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int")
   }

   ; sqlite3_column_bytes16
   sqlite3_column_count(Stmt) {
      static sqlite3_column_count := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_count")
      return DllCall(sqlite3_column_count
         , "Ptr", Stmt
         , "Cdecl Int")
   }
   ; sqlite3_column_database_name
   ; sqlite3_column_database_name16
   ; sqlite3_column_decltype
   ; sqlite3_column_decltype16
   sqlite3_column_double(stmt, Column) {
      static sqlite3_column_double := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_double")
      return DllCall(sqlite3_column_double
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Double")
   }
   ; sqlite3_column_int
   sqlite3_column_int64(stmt, Column) {
      static sqlite3_column_int64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_int64")
      return DllCall(sqlite3_column_int64
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int64")
   }
   sqlite3_column_name(stmt, col) {
      static sqlite3_column_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_name")
      return DllCall(sqlite3_column_name
         , "Ptr", stmt
         , "Int", col
         , "Cdecl UPtr")
   }
   ; sqlite3_column_name16
   ; sqlite3_column_origin_name
   ; sqlite3_column_origin_name16
   ; sqlite3_column_table_name
   ; sqlite3_column_table_name16
   sqlite3_column_text(stmt, Column) {
      static sqlite3_column_text := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_text")
      return DllCall(sqlite3_column_text
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   ; sqlite3_column_text16
   sqlite3_column_type(stmt, Column) {
      static sqlite3_column_type := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_type")
      return DllCall(sqlite3_column_type
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int")
   }
   ; sqlite3_column_value
   ; sqlite3_commit_hook
   ; sqlite3_compileoption_get
   ; sqlite3_compileoption_used
   ; sqlite3_complete
   ; sqlite3_complete16
   ; sqlite3_config
   ; sqlite3_context_db_handle
   ; sqlite3_create_collation
   ; sqlite3_create_collation16
   ; sqlite3_create_collation_v2
   ; sqlite3_create_filename
   sqlite3_create_function(Name, Args, Enc, Param, Func) {
      static sqlite3_create_function := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_function")
      return DllCall(sqlite3_create_function
         , "Ptr", this._Handle
         , "AStr", Name
         , "Int", Args
         , "Int", Enc
         , "Ptr", Param
         , "Ptr", Func
         , "Ptr", 0
         , "Ptr", 0
         , "Cdecl Int")
   }
   ; sqlite3_create_function16
   ; sqlite3_create_function_v2
   ; sqlite3_create_module
   ; sqlite3_create_module_v2
   ; sqlite3_create_window_function
   sqlite3_data_count() {
      static sqlite3_data_count := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_data_count")
      return DllCall(sqlite3_data_count
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   ; sqlite3_database_file_object
   ; sqlite3_db_cacheflush
   sqlite3_db_config(optionCode,value) {
      static sqlite3_db_config := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_config")
      return DllCall(sqlite3_db_config
         , "Ptr", this._Handle
         , "Int", optionCode
         , "Int", value
         , "Ptr", 0
         , "Cdecl Int")
   }
   ; sqlite3_db_filename
   ; sqlite3_db_handle
   ; sqlite3_db_mutex
   ; sqlite3_db_name
   ; sqlite3_db_readonly
   ; sqlite3_db_release_memory
   ; sqlite3_db_status
   ; sqlite3_declare_vtab
   ; sqlite3_deserialize
   ; sqlite3_drop_modules
   ; sqlite3_enable_load_extension
   ; sqlite3_enable_shared_cache
   sqlite3_errcode() {
      static sqlite3_errcode := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_errcode")
      return DllCall(sqlite3_errcode
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_errmsg() {
      static sqlite3_errmsg := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_errmsg")
      return DllCall(sqlite3_errmsg
         , "Ptr", this._Handle
         , "Cdecl UPtr")
   }
   ; sqlite3_errmsg16
   ; sqlite3_error_offset
   sqlite3_errstr(ErrCode) {
      static sqlite3_errstr := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_errstr")
      return DllCall(sqlite3_errstr
         , "Int", ErrCode
         , "Cdecl UPtr")
   }
   sqlite3_exec(UTF8, CBPtr, ObjPtr, &Err) {
    static sqlite3_exec := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_exec")
    return DllCall(sqlite3_exec
        , "Ptr", this._Handle
        , "Ptr", UTF8
        , "Int", CBPtr
        , "Ptr", ObjPtr
        , "UPtrP", &Err
        , "Cdecl Int")
   }

   ; sqlite3_expanded_sql
   ; sqlite3_expired
   sqlite3_extended_errcode() {
      static sqlite3_extended_errcode := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_extended_errcode")
      return DllCall(sqlite3_extended_errcode
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   ; sqlite3_extended_result_codes
   ; sqlite3_file_control
   ; sqlite3_filename_database
   ; sqlite3_filename_journal
   ; sqlite3_filename_wal
   sqlite3_finalize(Ptr) {
      static sqlite3_finalize := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_finalize")
      return DllCall(sqlite3_finalize
         , "Ptr", Ptr
         , "Cdecl Int")
   }
   sqlite3_free(Err) {
      static sqlite3_free := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_free")
      return DllCall(sqlite3_free
         , "Ptr", Err
         , "Cdecl")
   }
   ; sqlite3_free_filename
   sqlite3_free_table(Table) {
      static sqlite3_free_table := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_free_table")
      return DllCall(sqlite3_free_table
         , "Ptr", Table
         , "Cdecl")
   }

   ; sqlite3_get_autocommit
   ; sqlite3_get_auxdata
   ; sqlite3_get_clientdata
   sqlite3_get_table(UTF8, &Table, &Rows, &Cols, &Err) {    ; https://www.sqlite.org/c3ref/get_table.html
      static get_table := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_get_table")
      return DllCall(get_table
         , "Ptr", this._Handle
         , "Ptr", UTF8
         , "UPtrP", &Table
         , "IntP", &Rows
         , "IntP", &Cols
         , "UPtrP", &Err
         , "Cdecl Int")
   }
   ; sqlite3_global_recover
   ; sqlite3_hard_heap_limit64
   ; sqlite3_initialize
   ; sqlite3_interrupt
   ; sqlite3_is_interrupted
   ; sqlite3_keyword_check
   ; sqlite3_keyword_count
   ; sqlite3_keyword_name
   sqlite3_last_insert_rowid() {
      static sqlite3_last_insert_rowid := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_last_insert_rowid")
      return DllCall(sqlite3_last_insert_rowid
         , "Ptr", this._Handle
         , "Cdecl Int64")
   }
   sqlite3_libversion() {
      static libversion := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_libversion")
      return DllCall(libversion, "Cdecl UPtr")
   }
   ; sqlite3_libversion_number
   ; sqlite3_limit
   sqlite3_load_extension(File, Proc) {
      static sqlite3_load_extension := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_load_extension")
      return DllCall(sqlite3_load_extension
         , "Ptr", this._Handle
         , "AStr", File
         , "AStr", Proc
         , "Ptr", 0
         , "Cdecl Int")
   }
   ; sqlite3_log
   ; sqlite3_malloc
   ; sqlite3_malloc64
   ; sqlite3_memory_alarm
   ; sqlite3_memory_highwater
   ; sqlite3_memory_used
   sqlite3_mprintf(OP, UTF8) {
      static sqlite3_mprintf := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mprintf")
      return DllCall(sqlite3_mprintf
         , "Ptr", OP
         , "Ptr", UTF8
         , "Cdecl UPtr")
   }
   ; sqlite3_msize
   ; sqlite3_mutex_alloc
   ; sqlite3_mutex_enter
   ; sqlite3_mutex_free
   ; sqlite3_mutex_held
   ; sqlite3_mutex_leave
   ; sqlite3_mutex_notheld
   ; sqlite3_mutex_try
   ; sqlite3_next_stmt
   ; sqlite3_normalized_sql
   ; sqlite3_open
   ; sqlite3_open16
   sqlite3_open_v2(UTF8, &HDB, Flags) {
      static sqlite3_open_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_open_v2")
      return DllCall(sqlite3_open_v2
         , "Ptr", UTF8
         , "UPtrP", &HDB
         , "Int", Flags
         , "Ptr", 0
         , "Cdecl Int")
   }
   ; sqlite3_os_end
   ; sqlite3_os_init
   ; sqlite3_overload_function
   ; sqlite3_prepare
   ; sqlite3_prepare16
   ; sqlite3_prepare16_v2
   ; sqlite3_prepare16_v3
   sqlite3_prepare_v2(UTF8, &Stmt) {
      static sqlite3_prepare_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_prepare_v2")
      return DllCall(sqlite3_prepare_v2
         , "Ptr", this._Handle
         , "Ptr", UTF8
         , "Int", -1
         , "UPtrP", &Stmt
         , "Ptr", 0
         , "Cdecl Int")
   }

   ; sqlite3_prepare_v3
   ; sqlite3_preupdate_blobwrite
   ; sqlite3_preupdate_count
   ; sqlite3_preupdate_depth
   ; sqlite3_preupdate_hook
   ; sqlite3_preupdate_new
   ; sqlite3_preupdate_old
   ; sqlite3_profile
   ; sqlite3_progress_handler
   ; sqlite3_randomness
   ; sqlite3_realloc
   ; sqlite3_realloc64
   ; sqlite3_release_memory
   sqlite3_reset(Ptr) {
      static sqlite3_reset := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_reset")
      return DllCall(sqlite3_reset
         , "Ptr", Ptr
         , "Cdecl Int")
   }
   ; sqlite3_reset_auto_extension
   ; sqlite3_result_blob
   ; sqlite3_result_blob64
   ; sqlite3_result_double
   ; sqlite3_result_error
   ; sqlite3_result_error16
   ; sqlite3_result_error_code
   ; sqlite3_result_error_nomem
   ; sqlite3_result_error_toobig
   ; sqlite3_result_int
   ; sqlite3_result_int64
   ; sqlite3_result_null
   ; sqlite3_result_pointer
   ; sqlite3_result_subtype
   ; sqlite3_result_text
   ; sqlite3_result_text16
   ; sqlite3_result_text16be
   ; sqlite3_result_text16le
   ; sqlite3_result_text64
   ; sqlite3_result_value
   ; sqlite3_result_zeroblob
   ; sqlite3_result_zeroblob64
   ; sqlite3_rollback_hook
   ; sqlite3_serialize
   ; sqlite3_set_authorizer
   ; sqlite3_set_auxdata
   ; sqlite3_set_clientdata
   ; sqlite3_set_last_insert_rowid
   ; sqlite3_shutdown
   ; sqlite3_sleep
   ; sqlite3_snapshot_cmp
   ; sqlite3_snapshot_free
   ; sqlite3_snapshot_get
   ; sqlite3_snapshot_open
   ; sqlite3_snapshot_recover
   ; sqlite3_snprintf
   ; sqlite3_soft_heap_limit
   ; sqlite3_soft_heap_limit64
   ; sqlite3_sourceid
   ; sqlite3_sql
   ; sqlite3_status
   ; sqlite3_status64
   sqlite3_step(Ptr) {  ;https://sqlite.org/c3ref/step.html
      static sqlite3_step := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_step")
      return DllCall(sqlite3_step
         , "Ptr", Ptr
         , "Cdecl Int")
   }
   ; sqlite3_stmt_busy
   ; sqlite3_stmt_explain
   ; sqlite3_stmt_isexplain
   ; sqlite3_stmt_readonly
   ; sqlite3_stmt_scanstatus
   ; sqlite3_stmt_scanstatus_reset
   ; sqlite3_stmt_scanstatus_v2
   ; sqlite3_stmt_status
   ; sqlite3_str_append
   ; sqlite3_str_appendall
   ; sqlite3_str_appendchar
   ; sqlite3_str_appendf
   ; sqlite3_str_errcode
   ; sqlite3_str_finish
   ; sqlite3_str_length
   ; sqlite3_str_new
   ; sqlite3_str_reset
   ; sqlite3_str_value
   ; sqlite3_str_vappendf
   ; sqlite3_strglob
   ; sqlite3_stricmp
   ; sqlite3_strlike
   ; sqlite3_strnicmp
   ; sqlite3_system_errno
   ; sqlite3_table_column_metadata
   ; sqlite3_test_control
   ; sqlite3_thread_cleanup
   ; sqlite3_threadsafe
   sqlite3_total_changes() {
      static sqlite3_total_changes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_total_changes")
      return DllCall(sqlite3_total_changes
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   ; sqlite3_total_changes64
   ; sqlite3_trace
   ; sqlite3_trace_v2
   ; sqlite3_transfer_bindings
   ; sqlite3_txn_state
   ; sqlite3_unlock_notify
   ; sqlite3_update_hook
   ; sqlite3_uri_boolean
   ; sqlite3_uri_int64
   ; sqlite3_uri_key
   ; sqlite3_uri_parameter
   ; sqlite3_user_data
   ; sqlite3_value_blob
   ; sqlite3_value_bytes
   ; sqlite3_value_bytes16
   ; sqlite3_value_double
   ; sqlite3_value_dup
   ; sqlite3_value_encoding
   ; sqlite3_value_free
   ; sqlite3_value_frombind
   ; sqlite3_value_int
   ; sqlite3_value_int64
   ; sqlite3_value_nochange
   ; sqlite3_value_numeric_type
   ; sqlite3_value_pointer
   ; sqlite3_value_subtype
   ; sqlite3_value_text
   ; sqlite3_value_text16
   ; sqlite3_value_text16be
   ; sqlite3_value_text16le
   ; sqlite3_value_type
   ; sqlite3_version
   ; sqlite3_vfs_find
   ; sqlite3_vfs_register
   ; sqlite3_vfs_unregister
   ; sqlite3_vmprintf
   ; sqlite3_vsnprintf
   ; sqlite3_vtab_collation
   ; sqlite3_vtab_config
   ; sqlite3_vtab_distinct
   ; sqlite3_vtab_in
   ; sqlite3_vtab_in_first
   ; sqlite3_vtab_in_next
   ; sqlite3_vtab_nochange
   ; sqlite3_vtab_on_conflict
   ; sqlite3_vtab_rhs_value
   ; sqlite3_wal_autocheckpoint
   ; sqlite3_wal_checkpoint
   ; sqlite3_wal_checkpoint_v2
   ; sqlite3_wal_hook
   ; sqlite3_win32_set_directory
   ; sqlite3_win32_set_directory16
   ; sqlite3_win32_set_directory8
   _getDllAddress(dllPath,dllfunction){
        return DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandle", "Str", dllPath, "Ptr"), "AStr", dllfunction, "Ptr")
    }
}
; ======================================================================================================================
; Exemplary custom callback function regexp()
; Parameters:        Context  -  handle to a sqlite3_context object
;                    ArgC     -  number of elements passed in Values (must be 2 for this function)
;                    Values   -  pointer to an array of pointers which can be passed to sqlite3_value_text():
;                                1. Needle
;                                2. Haystack
; Return values:     Call sqlite3_result_int() passing 1 (True) for a match, otherwise pass 0 (False).
; ======================================================================================================================
SQriLiteDB_RegExp(Context, ArgC, Values) {
   Local AddrH, AddrN, Result := 0
   If (ArgC = 2) {
      AddrN := DllCall("SQLite3.dll\sqlite3_value_text", "Ptr", NumGet(Values + 0, "UPtr"), "Cdecl UPtr")
      AddrH := DllCall("SQLite3.dll\sqlite3_value_text", "Ptr", NumGet(Values + A_PtrSize, "UPtr"), "Cdecl UPtr")
      Result := RegExMatch(StrGet(AddrH, "UTF-8"), StrGet(AddrN, "UTF-8"))
   }
   DllCall("SQLite3.dll\sqlite3_result_int", "Ptr", Context, "Int", !!Result, "Cdecl") ; 0 = false, 1 = true
}
