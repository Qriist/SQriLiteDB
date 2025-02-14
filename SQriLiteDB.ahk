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
      If (RC := this.sqlite3_close(this._Handle))
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
         If (ClearBindings) && (RC := this._DB.sqlite3_clear_bindings(this._Handle))
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

   ;DLL functions
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
   sqlite3_clear_bindings(ptr) { ;untested   https://sqlite.org/c3ref/clear_bindings.html
      static sqlite3_clear_bindings := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_clear_bindings")
      return DllCall(sqlite3_clear_bindings
         , "Ptr", ptr
         , "Cdecl Int")
   }
   sqlite3_close(db) { ;https://sqlite.org/c3ref/close.html
      static sqlite3_close := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_close")
      return DllCall(sqlite3_close
         , "Ptr", db
         , "Cdecl Int")
   }
   sqlite3_close_v2(db) { ;untested   https://sqlite.org/c3ref/close.html
      static sqlite3_close_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_close_v2")
      return DllCall(sqlite3_close_v2
         , "Ptr", db
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
   sqlite3_column_blob(stmt, Column) { ;https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_blob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_blob")
      return DllCall(sqlite3_column_blob
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_bytes(stmt, Column) {   ;https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_bytes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_bytes")
      return DllCall(sqlite3_column_bytes
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int")
   }
   sqlite3_column_bytes16(stmt, Column) { ;untested   https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_bytes16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_bytes16")
      return DllCall(sqlite3_column_bytes16
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int")
   }
   sqlite3_column_count(Stmt) {  ;https://sqlite.org/c3ref/column_count.html
      static sqlite3_column_count := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_count")
      return DllCall(sqlite3_column_count
         , "Ptr", Stmt
         , "Cdecl Int")
   }
   sqlite3_column_database_name(stmt, Column) {       ;untested    https://sqlite.org/c3ref/column_database_name.html
      static sqlite3_column_database_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_database_name")
      return DllCall(sqlite3_column_database_name
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_database_name16(stmt, Column) {       ;untested    https://sqlite.org/c3ref/column_database_name.html
      static sqlite3_column_database_name16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_database_name16")
      return DllCall(sqlite3_column_database_name16
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_decltype(stmt, Column){    ; untested https://sqlite.org/c3ref/column_decltype.html
      static sqlite3_column_decltype := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_decltype")
      return DllCall(sqlite3_column_decltype
         ,   "Ptr", stmt
         ,   "Int", Column
         ,   "Cdecl")
   }
   sqlite3_column_decltype16(stmt, Column){    ; untested https://sqlite.org/c3ref/column_decltype.html
      static sqlite3_column_decltype16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_decltype16")
      return DllCall(sqlite3_column_decltype16
         ,   "Ptr", stmt
         ,   "Int", Column
         ,   "Cdecl")
   }
   sqlite3_column_double(stmt, Column) {  ;untested   https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_double := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_double")
      return DllCall(sqlite3_column_double
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Double")
   }
   sqlite3_column_int(stmt, Column) {  ;untested   https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_int := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_int")
      return DllCall(sqlite3_column_int
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int")
   }
   sqlite3_column_int64(stmt, Column) {   ;https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_int64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_int64")
      return DllCall(sqlite3_column_int64
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int64")
   }
   sqlite3_column_name(stmt, Column) {   ;https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_name")
      return DllCall(sqlite3_column_name
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_name16(stmt, Column) {       ;untested    https://sqlite.org/c3ref/column_name.html
      static sqlite3_column_name16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_name16")
      return DllCall(sqlite3_column_name16
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_origin_name(stmt, Column) {       ;untested    https://sqlite.org/c3ref/column_database_name.html
      static sqlite3_column_origin_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_origin_name")
      return DllCall(sqlite3_column_origin_name
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_origin_name16(stmt, Column) {       ;untested    https://sqlite.org/c3ref/column_database_name.html
      static sqlite3_column_origin_name16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_origin_name16")
      return DllCall(sqlite3_column_origin_name16
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_table_name(stmt, Column) {       ;untested    https://sqlite.org/c3ref/column_database_name.html
      static sqlite3_column_table_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_table_name")
      return DllCall(sqlite3_column_table_name
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_table_name16(stmt, Column) {       ;untested    https://sqlite.org/c3ref/column_database_name.html
      static sqlite3_column_table_name16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_table_name16")
      return DllCall(sqlite3_column_table_name16
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_text(stmt, Column) { ;https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_text := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_text")
      return DllCall(sqlite3_column_text
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_column_type(stmt, Column) { ;untested   https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_type := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_type")
      return DllCall(sqlite3_column_type
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl Int")
   }
   sqlite3_column_value(stmt, Column) {  ;untested   https://sqlite.org/c3ref/column_blob.html
      static sqlite3_column_value := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_column_value")
      return DllCall(sqlite3_column_value
         , "Ptr", stmt
         , "Int", Column
         , "Cdecl UPtr")
   }
   sqlite3_commit_hook(db, xCallback, pArg) {       ;untested    https://sqlite.org/c3ref/commit_hook.html
      static sqlite3_commit_hook := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_commit_hook")
      return DllCall(sqlite3_commit_hook
         , "Ptr", db
         , "Ptr", xCallback
         , "Ptr", pArg
         , "Cdecl Ptr")
   }
   sqlite3_compileoption_used(zOptName) {       ;untested    https://sqlite.org/c3ref/compileoption_used.html
      static sqlite3_compileoption_used := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_compileoption_used")
      return DllCall(sqlite3_compileoption_used
         , "AStr", zOptName
         , "Cdecl Int")
   }
   sqlite3_compileoption_get(N) {       ;untested    https://sqlite.org/c3ref/compileoption_used.html
      static sqlite3_compileoption_get := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_compileoption_get")
      return DllCall(sqlite3_compileoption_get
         , "Int", N
         , "Cdecl UPtr")
   }
   sqlite3_complete(sql) {       ;untested    https://sqlite.org/c3ref/complete.html
      static sqlite3_complete := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_complete")
      return DllCall(sqlite3_complete
         , "AStr", sql
         , "Cdecl Int")
   }
   sqlite3_complete16(sql) {       ;untested    https://sqlite.org/c3ref/complete.html
      static sqlite3_complete16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_complete16")
      return DllCall(sqlite3_complete16
         , "Ptr", sql
         , "Cdecl Int")
   }
   sqlite3_context_db_handle(ctx) {       ;untested    https://sqlite.org/c3ref/context_db_handle.html
      static sqlite3_context_db_handle := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_context_db_handle")
      return DllCall(sqlite3_context_db_handle
         , "Ptr", ctx
         , "Cdecl Ptr")
   }
   sqlite3_create_collation(db, zName, eTextRep, pArg, xCompare) {       ;untested    https://sqlite.org/c3ref/create_collation.html
      static sqlite3_create_collation := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_collation")
      return DllCall(sqlite3_create_collation
         , "Ptr", db
         , "AStr", zName
         , "Int", eTextRep
         , "Ptr", pArg
         , "Ptr", xCompare
         , "Cdecl Int")
   }
   sqlite3_create_collation_v2(db, zName, eTextRep, pArg, xCompare, xDestroy) {       ;untested    https://sqlite.org/c3ref/create_collation.html
      static sqlite3_create_collation_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_collation_v2")
      return DllCall(sqlite3_create_collation_v2
         , "Ptr", db
         , "AStr", zName
         , "Int", eTextRep
         , "Ptr", pArg
         , "Ptr", xCompare
         , "Ptr", xDestroy
         , "Cdecl Int")
   }
   sqlite3_create_collation16(db, zName, eTextRep, pArg, xCompare) {       ;untested    https://sqlite.org/c3ref/create_collation.html
      static sqlite3_create_collation16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_collation16")
      return DllCall(sqlite3_create_collation16
         , "Ptr", db
         , "Ptr", zName
         , "Int", eTextRep
         , "Ptr", pArg
         , "Ptr", xCompare
         , "Cdecl Int")
   }
   sqlite3_create_filename(zDatabase, zJournal, zWal, nParam, azParam) {       ;untested    https://sqlite.org/c3ref/create_filename.html
      static sqlite3_create_filename := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_filename")
      return DllCall(sqlite3_create_filename
         , "AStr", zDatabase
         , "AStr", zJournal
         , "AStr", zWal
         , "Int", nParam
         , "Ptr", azParam
         , "Cdecl Ptr")
   }
   sqlite3_create_function(Name, Args, Enc, Param, Func) {  ;https://sqlite.org/c3ref/create_function.html
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
   sqlite3_create_function16(db, zFunctionName, nArg, eTextRep, pApp, xFunc, xStep, xFinal) {       ;untested    https://sqlite.org/c3ref/create_function.html
      static sqlite3_create_function16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_function16")
      return DllCall(sqlite3_create_function16
         , "Ptr", db
         , "Ptr", zFunctionName
         , "Int", nArg
         , "Int", eTextRep
         , "Ptr", pApp
         , "Ptr", xFunc
         , "Ptr", xStep
         , "Ptr", xFinal
         , "Cdecl Int")
   }
   sqlite3_create_function_v2(db, zFunctionName, nArg, eTextRep, pApp, xFunc, xStep, xFinal, xDestroy) {       ;untested    https://sqlite.org/c3ref/create_function.html
      static sqlite3_create_function_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_function_v2")
      return DllCall(sqlite3_create_function_v2
         , "Ptr", db
         , "AStr", zFunctionName
         , "Int", nArg
         , "Int", eTextRep
         , "Ptr", pApp
         , "Ptr", xFunc
         , "Ptr", xStep
         , "Ptr", xFinal
         , "Ptr", xDestroy
         , "Cdecl Int")
   }
   sqlite3_create_module(db, zName, p, pClientData) {       ;untested    https://sqlite.org/c3ref/create_module.html
      static sqlite3_create_module := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_module")
      return DllCall(sqlite3_create_module
         , "Ptr", db
         , "AStr", zName
         , "Ptr", p
         , "Ptr", pClientData
         , "Cdecl Int")
   }
   sqlite3_create_module_v2(db, zName, p, pClientData, xDestroy) {       ;untested    https://sqlite.org/c3ref/create_module.html
      static sqlite3_create_module_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_module_v2")
      return DllCall(sqlite3_create_module_v2
         , "Ptr", db
         , "AStr", zName
         , "Ptr", p
         , "Ptr", pClientData
         , "Ptr", xDestroy
         , "Cdecl Int")
   }
   sqlite3_create_window_function(db, zFunctionName, nArg, eTextRep, pApp, xStep, xFinal, xValue, xInverse, xDestroy) {       ;untested    https://sqlite.org/c3ref/create_function.html
      static sqlite3_create_window_function := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_create_window_function")
      return DllCall(sqlite3_create_window_function
         , "Ptr", db
         , "AStr", zFunctionName
         , "Int", nArg
         , "Int", eTextRep
         , "Ptr", pApp
         , "Ptr", xStep
         , "Ptr", xFinal
         , "Ptr", xValue
         , "Ptr", xInverse
         , "Ptr", xDestroy
         , "Cdecl Int")
   }
   sqlite3_data_count() {  ;untested   https://sqlite.org/c3ref/data_count.html
      static sqlite3_data_count := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_data_count")
      return DllCall(sqlite3_data_count
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_database_file_object(zName) {       ;untested    https://sqlite.org/c3ref/database_file_object.html
      static sqlite3_database_file_object := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_database_file_object")
      return DllCall(sqlite3_database_file_object
         , "AStr", zName
         , "Cdecl Ptr")
   }
   sqlite3_db_cacheflush(db) {       ;untested    https://sqlite.org/c3ref/db_cacheflush.html
      static sqlite3_db_cacheflush := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_cacheflush")
      return DllCall(sqlite3_db_cacheflush
         , "Ptr", db
         , "Cdecl Int")
   }
   sqlite3_db_config(optionCode,value) {  ;https://sqlite.org/c3ref/config.html
      static sqlite3_db_config := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_config")
      return DllCall(sqlite3_db_config
         , "Ptr", this._Handle
         , "Int", optionCode
         , "Int", value
         , "Ptr", 0
         , "Cdecl Int")
   }
   sqlite3_db_filename(db, zDbName) {       ;untested    https://sqlite.org/c3ref/db_filename.html
      static sqlite3_db_filename := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_filename")
      return DllCall(sqlite3_db_filename
         , "Ptr", db
         , "AStr", zDbName
         , "Cdecl Ptr")
   }
   sqlite3_db_handle(stmt) {       ;untested    https://sqlite.org/c3ref/db_handle.html
      static sqlite3_db_handle := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_handle")
      return DllCall(sqlite3_db_handle
         , "Ptr", stmt
         , "Cdecl Ptr")
   }
   sqlite3_db_mutex(db) {       ;untested    https://sqlite.org/c3ref/db_mutex.html
      static sqlite3_db_mutex := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_mutex")
      return DllCall(sqlite3_db_mutex
         , "Ptr", db
         , "Cdecl Ptr")
   }
   sqlite3_db_name(db, N) {       ;untested    https://sqlite.org/c3ref/db_name.html
      static sqlite3_db_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_name")
      return DllCall(sqlite3_db_name
         , "Ptr", db
         , "Int", N
         , "Cdecl Ptr")
   }
   sqlite3_db_readonly(db, zDbName) {       ;untested    https://sqlite.org/c3ref/db_readonly.html
      static sqlite3_db_readonly := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_readonly")
      return DllCall(sqlite3_db_readonly
         , "Ptr", db
         , "AStr", zDbName
         , "Cdecl Int")
   }
   sqlite3_db_release_memory(db) {       ;untested    https://sqlite.org/c3ref/db_release_memory.html
      static sqlite3_db_release_memory := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_release_memory")
      return DllCall(sqlite3_db_release_memory
         , "Ptr", db
         , "Cdecl Int")
   }
   sqlite3_db_status(db, op, pCur, pHiwtr, resetFlg) {       ;untested    https://sqlite.org/c3ref/db_status.html
      static sqlite3_db_status := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_db_status")
      return DllCall(sqlite3_db_status
         , "Ptr", db
         , "Int", op
         , "Ptr", pCur
         , "Ptr", pHiwtr
         , "Int", resetFlg
         , "Cdecl Int")
   }
   sqlite3_declare_vtab(db, zSQL) {       ;untested    https://sqlite.org/c3ref/declare_vtab.html
      static sqlite3_declare_vtab := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_declare_vtab")
      return DllCall(sqlite3_declare_vtab
         , "Ptr", db
         , "Str", zSQL
         , "Cdecl Int")
   }
   sqlite3_deserialize(db, zSchema, pData, szDb, szBuf, mFlags) {       ;untested    https://sqlite.org/c3ref/deserialize.html
      static sqlite3_deserialize := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_deserialize")
      return DllCall(sqlite3_deserialize
         , "Ptr", db
         , "Str", zSchema
         , "Ptr", pData
         , "Int64", szDb
         , "Int64", szBuf
         , "UInt", mFlags
         , "Cdecl Int")
   }
   sqlite3_drop_modules(db, azKeep) {       ;untested    https://sqlite.org/c3ref/drop_modules.html
      static sqlite3_drop_modules := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_drop_modules")
      return DllCall(sqlite3_drop_modules
         , "Ptr", db
         , "Ptr", azKeep
         , "Cdecl Int")
   }
   sqlite3_enable_load_extension(db, onoff) {       ;untested    https://sqlite.org/c3ref/enable_load_extension.html
      static sqlite3_enable_load_extension := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_enable_load_extension")
      return DllCall(sqlite3_enable_load_extension
         , "Ptr", db
         , "Int", onoff
         , "Cdecl Int")
   }
   sqlite3_enable_shared_cache(onoff) {       ;untested    https://sqlite.org/c3ref/enable_shared_cache.html
      static sqlite3_enable_shared_cache := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_enable_shared_cache")
      return DllCall(sqlite3_enable_shared_cache
         , "Int", onoff
         , "Cdecl Int")
   }
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
   sqlite3_errmsg16(db) {       ;untested    https://sqlite.org/c3ref/errcode.html
      static sqlite3_errmsg16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_errmsg16")
      return DllCall(sqlite3_errmsg16
         , "Ptr", db
         , "Cdecl UPtr")
   }
   sqlite3_error_offset(db) {       ;untested    https://sqlite.org/c3ref/errcode.html
      static sqlite3_error_offset := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_error_offset")
      return DllCall(sqlite3_error_offset
         , "Ptr", db
         , "Cdecl Int")
   }
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
   sqlite3_expanded_sql(stmt) {       ;untested    https://sqlite.org/c3ref/expanded_sql.html
      static sqlite3_expanded_sql := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_expanded_sql")
      return DllCall(sqlite3_expanded_sql
         , "Ptr", stmt
         , "Cdecl Str")
   }
   sqlite3_extended_errcode() {
      static sqlite3_extended_errcode := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_extended_errcode")
      return DllCall(sqlite3_extended_errcode
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_extended_result_codes(db, onoff) {    ;untested    https://sqlite.org/c3ref/extended_result_codes.html
      static sqlite3_extended_result_codes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_extended_result_codes")
      return DllCall(sqlite3_extended_result_codes
         , "Ptr", db
         , "Int", onoff
         , "Cdecl Int")
   }
   sqlite3_file_control(db, zDbName, op, pArg) {    ;untested  https://sqlite.org/c3ref/file_control.html
      static sqlite3_file_control := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_file_control")
      return DllCall(sqlite3_file_control
         , "Ptr", db
         , "AStr", zDbName
         , "Int", op
         , "Ptr", pArg
         , "Cdecl Int")
   }
   sqlite3_filename_database(z) {       ;untested    https://sqlite.org/c3ref/filename_database.html
      static sqlite3_filename_database := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_filename_database")
      return DllCall(sqlite3_filename_database
         , "Ptr", z
         , "Cdecl AStr")
   }
   sqlite3_filename_journal(z) {       ;untested    https://sqlite.org/c3ref/filename_database.html
      static sqlite3_filename_journal := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_filename_journal")
      return DllCall(sqlite3_filename_journal
         , "Ptr", z
         , "Cdecl AStr")
   }
   sqlite3_filename_wal(z) {       ;untested    https://sqlite.org/c3ref/filename_database.html
      static sqlite3_filename_wal := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_filename_wal")
      return DllCall(sqlite3_filename_wal
         , "Ptr", z
         , "Cdecl AStr")
   }
   sqlite3_finalize(Ptr) { ;https://sqlite.org/c3ref/finalize.html
      static sqlite3_finalize := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_finalize")
      return DllCall(sqlite3_finalize
         , "Ptr", Ptr
         , "Cdecl Int")
   }
   sqlite3_free(ptr) {  ;https://sqlite.org/c3ref/free.html
      static sqlite3_free := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_free")
      return DllCall(sqlite3_free
         , "Ptr", ptr
         , "Cdecl")
   }
   sqlite3_free_filename(filename) {       ;untested    https://sqlite.org/c3ref/create_filename.html
      static sqlite3_free_filename := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_free_filename")
      DllCall(sqlite3_free_filename
         , "Ptr", filename
         , "Cdecl")
   }
   sqlite3_free_table(Table) {   ;https://sqlite.org/c3ref/create_filename.html
      static sqlite3_free_table := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_free_table")
      return DllCall(sqlite3_free_table
         , "Ptr", Table
         , "Cdecl")
   }
   sqlite3_get_autocommit(db) {       ;untested    https://sqlite.org/c3ref/get_autocommit.html
      static sqlite3_get_autocommit := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_get_autocommit")
      return DllCall(sqlite3_get_autocommit
         , "Ptr", db
         , "Cdecl Int")
   }
   sqlite3_get_auxdata(ctx, N) {       ;untested    https://sqlite.org/c3ref/get_auxdata.html
      static sqlite3_get_auxdata := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_get_auxdata")
      return DllCall(sqlite3_get_auxdata
         , "Ptr", ctx
         , "Int", N
         , "Cdecl UPtr")
   }
   sqlite3_get_clientdata(db, zName) {       ;untested    https://sqlite.org/c3ref/get_clientdata.html
      static sqlite3_get_clientdata := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_get_clientdata")
      return DllCall(sqlite3_get_clientdata
         , "Ptr", db
         , "AStr", zName
         , "Cdecl UPtr")
   }
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
   sqlite3_hard_heap_limit64(N) {       ;untested    https://sqlite.org/c3ref/hard_heap_limit64.html
      static sqlite3_hard_heap_limit64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_hard_heap_limit64")
      return DllCall(sqlite3_hard_heap_limit64
         , "Int64", N
         , "Cdecl Int64")
   }
   sqlite3_initialize() {       ;untested    https://sqlite.org/c3ref/initialize.html
      static sqlite3_initialize := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_initialize")
      return DllCall(sqlite3_initialize
         , "Cdecl Int")
   }
   sqlite3_interrupt(db) {       ;untested    https://sqlite.org/c3ref/interrupt.html
      static sqlite3_interrupt := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_interrupt")
      DllCall(sqlite3_interrupt
         , "Ptr", db
         , "Cdecl")
   }
   sqlite3_is_interrupted(db) {       ;untested    https://sqlite.org/c3ref/interrupt.html
      static sqlite3_is_interrupted := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_is_interrupted")
      return DllCall(sqlite3_is_interrupted
         , "Ptr", db
         , "Cdecl Int")
   }
   sqlite3_keyword_check(zKeyword, nByte) {       ;untested    https://sqlite.org/c3ref/keyword_check.html
      static sqlite3_keyword_check := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_keyword_check")
      return DllCall(sqlite3_keyword_check
         , "AStr", zKeyword
         , "Int", nByte
         , "Cdecl Int")
   }
   sqlite3_keyword_count() {       ;untested    https://sqlite.org/c3ref/keyword_check.html
      static sqlite3_keyword_count := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_keyword_count")
      return DllCall(sqlite3_keyword_count
         , "Cdecl Int")
   }
   sqlite3_keyword_name(i, pzName, pnName) {       ;untested    https://sqlite.org/c3ref/keyword_check.html
      static sqlite3_keyword_name := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_keyword_name")
      return DllCall(sqlite3_keyword_name
         , "Int", i
         , "UPtrP", &pzName
         , "IntP", &pnName
         , "Cdecl Int")
   }
   sqlite3_last_insert_rowid() { ;https://sqlite.org/c3ref/last_insert_rowid.html
      static sqlite3_last_insert_rowid := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_last_insert_rowid")
      return DllCall(sqlite3_last_insert_rowid
         , "Ptr", this._Handle
         , "Cdecl Int64")
   }
   sqlite3_libversion() {  ;https://sqlite.org/c3ref/libversion.html
      static libversion := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_libversion")
      return DllCall(libversion, "Cdecl UPtr")
   }
   sqlite3_libversion_number() {       ;untested    https://sqlite.org/c3ref/libversion.html
      static sqlite3_libversion_number := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_libversion_number")
      return DllCall(sqlite3_libversion_number
         , "Cdecl Int")
   }
   sqlite3_limit(db, id, newVal) {       ;untested    https://sqlite.org/c3ref/limit.html
      static sqlite3_limit := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_limit")
      return DllCall(sqlite3_limit
         , "Ptr", db
         , "Int", id
         , "Int", newVal
         , "Cdecl Int")
   }
   sqlite3_load_extension(File, Proc, &ErrMsg?) {  ;https://sqlite.org/c3ref/load_extension.html
      static sqlite3_load_extension := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_load_extension")
      return DllCall(sqlite3_load_extension
         , "Ptr", this._Handle
         , "AStr", File
         , "AStr", Proc
         , "Ptr", &ErrMsg
         , "Cdecl Int")
   }
   sqlite3_log(iErrCode, zFormat) {    ;untested    https://sqlite.org/c3ref/log.html
      static sqlite3_log := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_log")
      return DllCall(sqlite3_log
         , "Int", iErrCode
         , "AStr", zFormat
         , "Cdecl Int")
   }
   sqlite3_malloc(size) {       ;untested    https://sqlite.org/c3ref/free.html
      static sqlite3_malloc := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_malloc")
      return DllCall(sqlite3_malloc
         , "Int", size
         , "Cdecl Ptr")
   }
   sqlite3_malloc64(size) {       ;untested    https://sqlite.org/c3ref/free.html
      static sqlite3_malloc64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_malloc64")
      return DllCall(sqlite3_malloc64
         , "UInt64", size
         , "Cdecl Ptr")
   }
   sqlite3_memory_used() {    ;untested    https://sqlite.org/c3ref/memory_highwater.html
      static sqlite3_memory_used := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_memory_used")
      return DllCall(sqlite3_memory_used
         , "Cdecl Int64")
   }
   sqlite3_memory_highwater(resetFlag) {    ;untested    https://sqlite.org/c3ref/memory_highwater.html
      static sqlite3_memory_highwater := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_memory_highwater")
      return DllCall(sqlite3_memory_highwater
         , "Int", resetFlag
         , "Cdecl Int64")
   }
   sqlite3_mprintf(OP, UTF8) {   ;https://sqlite.org/c3ref/mprintf.html
      static sqlite3_mprintf := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mprintf")
      return DllCall(sqlite3_mprintf
         , "Ptr", OP
         , "Ptr", UTF8
         , "Cdecl UPtr")
   }
   sqlite3_msize(ptr) {       ;untested    https://sqlite.org/c3ref/free.html
      static sqlite3_msize := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_msize")
      return DllCall(sqlite3_msize
         , "Ptr", ptr
         , "Cdecl UInt64")
   }
   sqlite3_mutex_alloc(iType){    ;untested    https://sqlite.org/c3ref/mutex_alloc.html
      static sqlite3_mutex_alloc := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mutex_alloc")
      return DllCall(sqlite3_mutex_alloc
         ,   "Int", iType
         ,   "Cdecl", "Ptr")
   }
   sqlite3_mutex_enter(pMutex){    ;untested    https://sqlite.org/c3ref/mutex_alloc.html
      static sqlite3_mutex_enter := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mutex_enter")
      DllCall(sqlite3_mutex_enter
         ,   "Ptr", pMutex
         ,   "Cdecl")
   }
   sqlite3_mutex_free(pMutex){    ;untested    https://sqlite.org/c3ref/mutex_alloc.html
      static sqlite3_mutex_free := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mutex_free")
      DllCall(sqlite3_mutex_free
         ,   "Ptr", pMutex
         ,   "Cdecl")
   }
   sqlite3_mutex_held(pMutex){    ;untested    https://sqlite.org/c3ref/mutex_held.html
      static sqlite3_mutex_held := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mutex_held")
      return DllCall(sqlite3_mutex_held
         ,   "Ptr", pMutex
         ,   "Cdecl", "Int")
   }
   sqlite3_mutex_leave(pMutex){    ;untested    https://sqlite.org/c3ref/mutex_alloc.html
      static sqlite3_mutex_leave := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mutex_leave")
      DllCall(sqlite3_mutex_leave
         ,   "Ptr", pMutex
         ,   "Cdecl")
   }
   sqlite3_mutex_notheld(pMutex){    ;untested    https://sqlite.org/c3ref/mutex_held.html
      static sqlite3_mutex_notheld := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mutex_notheld")
      return DllCall(sqlite3_mutex_notheld
         ,   "Ptr", pMutex
         ,   "Cdecl", "Int")
   }
   sqlite3_mutex_try(pMutex){    ;untested    https://sqlite.org/c3ref/mutex_alloc.html
      static sqlite3_mutex_try := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_mutex_try")
      return DllCall(sqlite3_mutex_try
         ,   "Ptr", pMutex
         ,   "Cdecl", "Int")
   }
   sqlite3_next_stmt(pDb, pStmt){    ;untested    https://sqlite.org/c3ref/next_stmt.html
      static sqlite3_next_stmt := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_next_stmt")
      return DllCall(sqlite3_next_stmt
         ,   "Ptr", pDb
         ,   "Ptr", pStmt
         ,   "Cdecl", "Ptr")
   }
   sqlite3_normalized_sql(stmt) {       ;untested    https://sqlite.org/c3ref/expanded_sql.html
      static sqlite3_normalized_sql := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_normalized_sql")
      return DllCall(sqlite3_normalized_sql
         , "Ptr", stmt
         , "Cdecl Str")
   }
   sqlite3_open(filename, ppDb){    ;untested    https://sqlite.org/c3ref/open.html
      static sqlite3_open := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_open")
      return DllCall(sqlite3_open
         ,   "Str", filename
         ,   "Ptr*", ppDb
         ,   "Cdecl", "Int")
   }
   sqlite3_open16(filename, ppDb){    ;untested    https://sqlite.org/c3ref/open.html
      static sqlite3_open16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_open16")
      return DllCall(sqlite3_open16
         ,   "Ptr", filename
         ,   "Ptr*", ppDb
         ,   "Cdecl", "Int")
   }
   sqlite3_open_v2(UTF8, &HDB, Flags) {   ;https://sqlite.org/c3ref/open.html
      static sqlite3_open_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_open_v2")
      return DllCall(sqlite3_open_v2
         , "Ptr", UTF8
         , "UPtrP", &HDB
         , "Int", Flags
         , "Ptr", 0
         , "Cdecl Int")
   }
   sqlite3_os_end() {       ;untested    https://sqlite.org/c3ref/initialize.html
      static sqlite3_os_end := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_os_end")
      return DllCall(sqlite3_os_end
         , "Cdecl Int")
   }
   sqlite3_os_init() {       ;untested    https://sqlite.org/c3ref/initialize.html
      static sqlite3_os_init := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_os_init")
      return DllCall(sqlite3_os_init
         , "Cdecl Int")
   }
   sqlite3_overload_function(db, zFuncName, nArg){    ;untested    https://sqlite.org/c3ref/overload_function.html
      static sqlite3_overload_function := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_overload_function")
      return DllCall(sqlite3_overload_function
         ,   "Ptr", db
         ,   "Str", zFuncName
         ,   "Int", nArg
         ,   "Cdecl", "Int")
   }
   sqlite3_prepare(db, zSql, nByte, ppStmt, pzTail){    ;untested    https://sqlite.org/c3ref/prepare.html
      static sqlite3_prepare := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_prepare")
      return DllCall(sqlite3_prepare
         ,   "Ptr", db
         ,   "Str", zSql
         ,   "Int", nByte
         ,   "Ptr", ppStmt
         ,   "Ptr", pzTail
         ,   "Cdecl", "Int")
   }
   sqlite3_prepare16(db, zSql, nByte, ppStmt, pzTail){    ;untested    https://sqlite.org/c3ref/prepare.html
      static sqlite3_prepare16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_prepare16")
      return DllCall(sqlite3_prepare16
         ,   "Ptr", db
         ,   "Ptr", zSql
         ,   "Int", nByte
         ,   "Ptr", ppStmt
         ,   "Ptr", pzTail
         ,   "Cdecl", "Int")
   }
   sqlite3_prepare16_v2(db, zSql, nByte, ppStmt, pzTail){    ;untested    https://sqlite.org/c3ref/prepare.html
      static sqlite3_prepare16_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_prepare16_v2")
      return DllCall(sqlite3_prepare16_v2
         ,   "Ptr", db
         ,   "Ptr", zSql
         ,   "Int", nByte
         ,   "Ptr", ppStmt
         ,   "Ptr", pzTail
         ,   "Cdecl", "Int")
   }
   sqlite3_prepare16_v3(db, zSql, nByte, prepFlags, ppStmt, pzTail){    ;untested    https://sqlite.org/c3ref/prepare.html
      static sqlite3_prepare16_v3 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_prepare16_v3")
      return DllCall(sqlite3_prepare16_v3
         ,   "Ptr", db
         ,   "Ptr", zSql
         ,   "Int", nByte
         ,   "UInt", prepFlags
         ,   "Ptr", ppStmt
         ,   "Ptr", pzTail
         ,   "Cdecl", "Int")
   }
   sqlite3_prepare_v2(UTF8, &Stmt) {    ;https://sqlite.org/c3ref/prepare.html
      static sqlite3_prepare_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_prepare_v2")
      return DllCall(sqlite3_prepare_v2
         , "Ptr", this._Handle
         , "Ptr", UTF8
         , "Int", -1
         , "UPtrP", &Stmt
         , "Ptr", 0
         , "Cdecl Int")
   }
   sqlite3_prepare_v3(db, zSql, nByte, prepFlags, ppStmt, pzTail){    ;untested    https://sqlite.org/c3ref/prepare.html
      static sqlite3_prepare_v3 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_prepare_v3")
      return DllCall(sqlite3_prepare_v3
         ,   "Ptr", db
         ,   "Str", zSql
         ,   "Int", nByte
         ,   "UInt", prepFlags
         ,   "Ptr", ppStmt
         ,   "Ptr", pzTail
         ,   "Cdecl", "Int")
   }
   sqlite3_preupdate_blobwrite(db){    ;untested    https://sqlite.org/c3ref/preupdate_blobwrite.html
      static sqlite3_preupdate_blobwrite := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_preupdate_blobwrite")
      return DllCall(sqlite3_preupdate_blobwrite
         ,   "Ptr", db
         ,   "Cdecl", "Int")
   }
   sqlite3_preupdate_count(db){    ;untested    https://sqlite.org/c3ref/preupdate_blobwrite.html
      static sqlite3_preupdate_count := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_preupdate_count")
      return DllCall(sqlite3_preupdate_count
         ,   "Ptr", db
         ,   "Cdecl", "Int")
   }
   sqlite3_preupdate_depth(db){    ;untested    https://sqlite.org/c3ref/preupdate_blobwrite.html
      static sqlite3_preupdate_depth := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_preupdate_depth")
      return DllCall(sqlite3_preupdate_depth
         ,   "Ptr", db
         ,   "Cdecl", "Int")
   }
   sqlite3_preupdate_hook(db, xPreUpdate, pCtx){    ;untested    https://sqlite.org/c3ref/preupdate_blobwrite.html
      static sqlite3_preupdate_hook := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_preupdate_hook")
      return DllCall(sqlite3_preupdate_hook
         ,   "Ptr", db
         ,   "Ptr", xPreUpdate
         ,   "Ptr", pCtx
         ,   "Cdecl", "Ptr")
   }
   sqlite3_preupdate_new(db, op, ppValue){    ;untested    https://sqlite.org/c3ref/preupdate_blobwrite.html
      static sqlite3_preupdate_new := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_preupdate_new")
      return DllCall(sqlite3_preupdate_new
         ,   "Ptr", db
         ,   "Int", op
         ,   "Ptr", ppValue
         ,   "Cdecl", "Int")
   }
   sqlite3_preupdate_old(db, op, ppValue){    ;untested    https://sqlite.org/c3ref/preupdate_blobwrite.html
      static sqlite3_preupdate_old := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_preupdate_old")
      return DllCall(sqlite3_preupdate_old
         ,   "Ptr", db
         ,   "Int", op
         ,   "Ptr", ppValue
         ,   "Cdecl", "Int")
   }
   sqlite3_progress_handler(db, nOps, xProgress, pCtx){    ; https://sqlite.org/c3ref/progress_handler.html
      static sqlite3_progress_handler := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_progress_handler")
      return DllCall(sqlite3_progress_handler
         ,   "Ptr", db
         ,   "Int", nOps
         ,   "Ptr", xProgress
         ,   "Ptr", pCtx
         ,   "Cdecl", "Int")
   }
   sqlite3_randomness(N, P){    ;untested https://sqlite.org/c3ref/randomness.html
      static sqlite3_randomness := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_randomness")
      return DllCall(sqlite3_randomness
         ,   "Int", N
         ,   "Ptr", P
         ,   "Cdecl", "Int")
   }
   sqlite3_realloc(ptr, size) {       ;untested    https://sqlite.org/c3ref/free.html
      static sqlite3_realloc := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_realloc")
      return DllCall(sqlite3_realloc
         , "Ptr", ptr
         , "Int", size
         , "Cdecl Ptr")
   }
   sqlite3_realloc64(ptr, size) {       ;untested    https://sqlite.org/c3ref/free.html
      static sqlite3_realloc64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_realloc64")
      return DllCall(sqlite3_realloc64
         , "Ptr", ptr
         , "UInt64", size
         , "Cdecl Ptr")
   }
   sqlite3_release_memory(N){    ;untested https://sqlite.org/c3ref/release_memory.html
      static sqlite3_release_memory := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_release_memory")
      return DllCall(sqlite3_release_memory
         ,   "Int", N
         ,   "Cdecl", "Int")
   }
   sqlite3_reset(stmt) { ;https://sqlite.org/c3ref/reset.html
      static sqlite3_reset := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_reset")
      return DllCall(sqlite3_reset
         , "Ptr", stmt
         , "Cdecl Int")
   }
   sqlite3_reset_auto_extension(){    ; untested https://sqlite.org/c3ref/reset_auto_extension.html
      static sqlite3_reset_auto_extension := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_reset_auto_extension")
      return DllCall(sqlite3_reset_auto_extension
         ,   "Cdecl", "Void")
   }
   sqlite3_result_blob(context, data, size, destroyFunc := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_blob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_blob")
      return DllCall(sqlite3_result_blob
         ,   "Ptr", context
         ,   "Ptr", data
         ,   "Int", size
         ,   "Ptr", destroyFunc
         ,   "Cdecl")
   }
   sqlite3_result_blob64(context, data, size64, destroyFunc := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_blob64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_blob64")
      return DllCall(sqlite3_result_blob64
         ,   "Ptr", context
         ,   "Ptr", data
         ,   "UInt64", size64
         ,   "Ptr", destroyFunc
         ,   "Cdecl")
   }
   sqlite3_result_double(context, value){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_double := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_double")
      return DllCall(sqlite3_result_double
         ,   "Ptr", context
         ,   "Double", value
         ,   "Cdecl")
   }
   sqlite3_result_error(context, errorMsg, size){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_error := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_error")
      return DllCall(sqlite3_result_error
         ,   "Ptr", context
         ,   "Str", errorMsg
         ,   "Int", size
         ,   "Cdecl")
   }
   sqlite3_result_error16(context, errorMsg, size){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_error16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_error16")
      return DllCall(sqlite3_result_error16
         ,   "Ptr", context
         ,   "Ptr", errorMsg
         ,   "Int", size
         ,   "Cdecl")
   }
   sqlite3_result_error_code(context, errorCode){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_error_code := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_error_code")
      return DllCall(sqlite3_result_error_code
         ,   "Ptr", context
         ,   "Int", errorCode
         ,   "Cdecl")
   }
   sqlite3_result_error_nomem(context){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_error_nomem := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_error_nomem")
      return DllCall(sqlite3_result_error_nomem
         ,   "Ptr", context
         ,   "Cdecl")
   }
   sqlite3_result_error_toobig(context){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_error_toobig := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_error_toobig")
      return DllCall(sqlite3_result_error_toobig
         ,   "Ptr", context
         ,   "Cdecl")
   }
   sqlite3_result_int(context, value){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_int := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_int")
      return DllCall(sqlite3_result_int
         ,   "Ptr", context
         ,   "Int", value
         ,   "Cdecl")
   }
   sqlite3_result_int64(context, value){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_int64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_int64")
      return DllCall(sqlite3_result_int64
         ,   "Ptr", context
         ,   "Int64", value
         ,   "Cdecl")
   }
   sqlite3_result_null(context){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_null := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_null")
      return DllCall(sqlite3_result_null
         ,   "Ptr", context
         ,   "Cdecl")
   }
   sqlite3_result_pointer(context, ptr, typeName, destroyFunc := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_pointer := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_pointer")
      return DllCall(sqlite3_result_pointer
         ,   "Ptr", context
         ,   "Ptr", ptr
         ,   "Str", typeName
         ,   "Ptr", destroyFunc
         ,   "Cdecl")
   }
   sqlite3_result_subtype(context, subtype){    ; untested https://sqlite.org/c3ref/result_subtype.html
      static sqlite3_result_subtype := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_subtype")
      return DllCall(sqlite3_result_subtype
         ,   "Ptr", context
         ,   "UInt", subtype
         ,   "Cdecl")
   }
   sqlite3_result_text(context, text, size, destroyFunc := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_text := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_text")
      return DllCall(sqlite3_result_text
         ,   "Ptr", context
         ,   "Str", text
         ,   "Int", size
         ,   "Ptr", destroyFunc
         ,   "Cdecl")
   }
   sqlite3_result_text16(context, text, size, destroyFunc := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_text16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_text16")
      return DllCall(sqlite3_result_text16
         ,   "Ptr", context
         ,   "Ptr", text
         ,   "Int", size
         ,   "Ptr", destroyFunc
         ,   "Cdecl")
   }
   sqlite3_result_text16be(context, text, size, destroyFunc := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_text16be := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_text16be")
      return DllCall(sqlite3_result_text16be
         ,   "Ptr", context
         ,   "Ptr", text
         ,   "Int", size
         ,   "Ptr", destroyFunc
         ,   "Cdecl")
   }
   sqlite3_result_text16le(context, text, size, destroyFunc := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_text16le := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_text16le")
      return DllCall(sqlite3_result_text16le
         ,   "Ptr", context
         ,   "Ptr", text
         ,   "Int", size
         ,   "Ptr", destroyFunc
         ,   "Cdecl")
   }
   sqlite3_result_text64(context, text, size64, destroyFunc := 0, encoding := 0){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_text64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_text64")
      return DllCall(sqlite3_result_text64
         ,   "Ptr", context
         ,   "Str", text
         ,   "UInt64", size64
         ,   "Ptr", destroyFunc
         ,   "UInt", encoding
         ,   "Cdecl")
   }
   sqlite3_result_value(context, value){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_value := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_value")
      return DllCall(sqlite3_result_value
         ,   "Ptr", context
         ,   "Ptr", value
         ,   "Cdecl")
   }
   sqlite3_result_zeroblob(context, size){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_zeroblob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_zeroblob")
      return DllCall(sqlite3_result_zeroblob
         ,   "Ptr", context
         ,   "Int", size
         ,   "Cdecl")
   }
   sqlite3_result_zeroblob64(context, size64){    ; untested https://sqlite.org/c3ref/result_blob.html
      static sqlite3_result_zeroblob64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_result_zeroblob64")
      return DllCall(sqlite3_result_zeroblob64
         ,   "Ptr", context
         ,   "UInt64", size64
         ,   "Cdecl")
   }
   sqlite3_rollback_hook(db, xCallback, pArg) { ;untested    https://sqlite.org/c3ref/commit_hook.html
      static sqlite3_rollback_hook := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_rollback_hook")
      return DllCall(sqlite3_rollback_hook
         , "Ptr", db
         , "Ptr", xCallback
         , "Ptr", pArg
         , "Cdecl Ptr")
   }
   sqlite3_serialize(db, zSchema, piSize, mFlags){    ; untested https://sqlite.org/c3ref/serialize.html
      static sqlite3_serialize := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_serialize")
      return DllCall(sqlite3_serialize
         ,   "Ptr", db
         ,   "Str", zSchema
         ,   "Ptr", piSize
         ,   "UInt", mFlags
         ,   "Cdecl")
   }
   sqlite3_set_authorizer(db, xAuth, pUserData){    ; untested https://sqlite.org/c3ref/set_authorizer.html
      static sqlite3_set_authorizer := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_set_authorizer")
      return DllCall(sqlite3_set_authorizer
         ,   "Ptr", db
         ,   "Ptr", xAuth
         ,   "Ptr", pUserData
         ,   "Cdecl")
   }
   sqlite3_set_auxdata(ctx, N, data, xDestroy) {       ;untested    https://sqlite.org/c3ref/get_auxdata.html
      static sqlite3_set_auxdata := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_set_auxdata")
      DllCall(sqlite3_set_auxdata
         , "Ptr", ctx
         , "Int", N
         , "Ptr", data
         , "Ptr", xDestroy
         , "Cdecl")
   }
   sqlite3_set_clientdata(db, zName, data, xDestroy) {       ;untested    https://sqlite.org/c3ref/get_clientdata.html
      static sqlite3_set_clientdata := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_set_clientdata")
      return DllCall(sqlite3_set_clientdata
         , "Ptr", db
         , "AStr", zName
         , "Ptr", data
         , "Ptr", xDestroy
         , "Cdecl Int")
   }
   sqlite3_set_last_insert_rowid(db, rowid){    ; untested https://sqlite.org/c3ref/set_last_insert_rowid.html
      static sqlite3_set_last_insert_rowid := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_set_last_insert_rowid")
      return DllCall(sqlite3_set_last_insert_rowid
         ,   "Ptr", db
         ,   "Int64", rowid
         ,   "Cdecl")
   }
   sqlite3_shutdown() {       ;untested    https://sqlite.org/c3ref/initialize.html
      static sqlite3_shutdown := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_shutdown")
      return DllCall(sqlite3_shutdown
         , "Cdecl Int")
   }
   sqlite3_sleep(ms){    ; untested https://sqlite.org/c3ref/sleep.html
      static sqlite3_sleep := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_sleep")
      return DllCall(sqlite3_sleep
         ,   "Int", ms
         ,   "Cdecl")
   }
   sqlite3_snapshot_cmp(p1, p2){    ; untested https://sqlite.org/c3ref/snapshot_cmp.html
      static sqlite3_snapshot_cmp := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_snapshot_cmp")
      return DllCall(sqlite3_snapshot_cmp
         ,   "Ptr", p1
         ,   "Ptr", p2
         ,   "Cdecl")
   }
   sqlite3_snapshot_free(pSnapshot){    ; untested https://sqlite.org/c3ref/snapshot_free.html
      static sqlite3_snapshot_free := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_snapshot_free")
      DllCall(sqlite3_snapshot_free
         ,   "Ptr", pSnapshot
         ,   "Cdecl")
   }
   sqlite3_snapshot_get(db, zSchema, &ppSnapshot){    ; untested https://sqlite.org/c3ref/snapshot_get.html
      static sqlite3_snapshot_get := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_snapshot_get")
      return DllCall(sqlite3_snapshot_get
         ,   "Ptr", db
         ,   "AStr", zSchema
         ,   "PtrP", ppSnapshot
         ,   "Cdecl")
   }
   sqlite3_snapshot_open(db, zSchema, pSnapshot){    ; untested https://sqlite.org/c3ref/snapshot_open.html
      static sqlite3_snapshot_open := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_snapshot_open")
      return DllCall(sqlite3_snapshot_open
         ,   "Ptr", db
         ,   "AStr", zSchema
         ,   "Ptr", pSnapshot
         ,   "Cdecl")
   }
   sqlite3_snapshot_recover(db, zDb){    ; untested https://sqlite.org/c3ref/snapshot_recover.html
      static sqlite3_snapshot_recover := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_snapshot_recover")
      return DllCall(sqlite3_snapshot_recover
         ,   "Ptr", db
         ,   "AStr", zDb
         ,   "Cdecl")
   }
   sqlite3_snprintf(n, zBuf, zFormat){    ;untested    https://sqlite.org/c3ref/mprintf.html
      static sqlite3_snprintf := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_snprintf")
      return DllCall(sqlite3_snprintf
         ,   "Int", n
         ,   "AStr", zBuf
         ,   "AStr", zFormat
         ,   "Cdecl", "Ptr")
   }
   sqlite3_soft_heap_limit64(N) {       ;untested    https://sqlite.org/c3ref/hard_heap_limit64.html
      static sqlite3_soft_heap_limit64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_soft_heap_limit64")
      return DllCall(sqlite3_soft_heap_limit64
         , "Int64", N
         , "Cdecl Int64")
   }
   sqlite3_sourceid() {       ;untested    https://sqlite.org/c3ref/libversion.html
      static sqlite3_sourceid := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_sourceid")
      return DllCall(sqlite3_sourceid
         , "Cdecl AShr")
   }
   sqlite3_sql(stmt) {       ;untested    https://sqlite.org/c3ref/expanded_sql.html
      static sqlite3_sql := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_sql")
      return DllCall(sqlite3_sql
         , "Ptr", stmt
         , "Cdecl Str")
   }
   sqlite3_status(op, pCurrent, pHighwater, resetFlag){    ; untested https://sqlite.org/c3ref/status.html
      static sqlite3_status := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_status")
      return DllCall(sqlite3_status
         ,   "Int", op
         ,   "Ptr", pCurrent
         ,   "Ptr", pHighwater
         ,   "Int", resetFlag
         ,   "Cdecl")
   }
   sqlite3_status64(op, pCurrent, pHighwater, resetFlag){    ; untested https://sqlite.org/c3ref/status.html
      static sqlite3_status64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_status64")
      return DllCall(sqlite3_status64
         ,   "Int", op
         ,   "Ptr", pCurrent
         ,   "Ptr", pHighwater
         ,   "Int", resetFlag
         ,   "Cdecl")
   }
   sqlite3_step(Ptr) {  ;https://sqlite.org/c3ref/step.html
      static sqlite3_step := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_step")
      return DllCall(sqlite3_step
         , "Ptr", Ptr
         , "Cdecl Int")
   }
   sqlite3_stmt_busy(stmt){    ; untested https://sqlite.org/c3ref/stmt_busy.html
      static sqlite3_stmt_busy := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_busy")
      return DllCall(sqlite3_stmt_busy
         ,   "Ptr", stmt
         ,   "Cdecl Int")
   }
   sqlite3_stmt_explain(stmt, eMode){    ; untested https://sqlite.org/c3ref/stmt_explain.html
      static sqlite3_stmt_explain := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_explain")
      return DllCall(sqlite3_stmt_explain
         ,   "Ptr", stmt
         ,   "Int", eMode
         ,   "Cdecl Int")
   }
   sqlite3_stmt_isexplain(stmt){    ; untested https://sqlite.org/c3ref/stmt_isexplain.html
      static sqlite3_stmt_isexplain := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_isexplain")
      return DllCall(sqlite3_stmt_isexplain
         ,   "Ptr", stmt
         ,   "Cdecl Int")
   }
   sqlite3_stmt_readonly(stmt){    ; untested https://sqlite.org/c3ref/stmt_readonly.html
      static sqlite3_stmt_readonly := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_readonly")
      return DllCall(sqlite3_stmt_readonly
         ,   "Ptr", stmt
         ,   "Cdecl Int")
   }
   sqlite3_stmt_scanstatus(stmt, idx, iScanStatusOp, pOut){    ; untested https://sqlite.org/c3ref/stmt_scanstatus.html
      static sqlite3_stmt_scanstatus := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_scanstatus")
      return DllCall(sqlite3_stmt_scanstatus
         ,   "Ptr", stmt
         ,   "Int", idx
         ,   "Int", iScanStatusOp
         ,   "Ptr", pOut
         ,   "Cdecl Int")
   }
   sqlite3_stmt_scanstatus_reset(stmt){    ; untested https://sqlite.org/c3ref/stmt_scanstatus_reset.html
      static sqlite3_stmt_scanstatus_reset := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_scanstatus_reset")
      DllCall(sqlite3_stmt_scanstatus_reset
         ,   "Ptr", stmt
         ,   "Cdecl")
   }
   sqlite3_stmt_scanstatus_v2(stmt, idx, iScanStatusOp, flags, pOut){    ; untested https://sqlite.org/c3ref/stmt_scanstatus.html
      static sqlite3_stmt_scanstatus_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_scanstatus_v2")
      return DllCall(sqlite3_stmt_scanstatus_v2
         ,   "Ptr", stmt
         ,   "Int", idx
         ,   "Int", iScanStatusOp
         ,   "Int", flags
         ,   "Ptr", pOut
         ,   "Cdecl Int")
   }
   sqlite3_stmt_status(stmt, op, resetFlg){    ; untested https://sqlite.org/c3ref/stmt_status.html
      static sqlite3_stmt_status := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stmt_status")
      return DllCall(sqlite3_stmt_status
         ,   "Ptr", stmt
         ,   "Int", op
         ,   "Int", resetFlg
         ,   "Cdecl")
   }
   sqlite3_str_append(pStr, zIn, N){    ; untested https://sqlite.org/c3ref/str_append.html
      static sqlite3_str_append := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_append")
      return DllCall(sqlite3_str_append
         ,   "Ptr", pStr
         ,   "Str", zIn
         ,   "Int", N
         ,   "Cdecl")
   }
   sqlite3_str_appendall(pStr, zIn){    ; untested https://sqlite.org/c3ref/str_append.html
      static sqlite3_str_appendall := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_appendall")
      return DllCall(sqlite3_str_appendall
         ,   "Ptr", pStr
         ,   "Str", zIn
         ,   "Cdecl")
   }
   sqlite3_str_appendchar(pStr, N, C){    ; untested https://sqlite.org/c3ref/str_append.html
      static sqlite3_str_appendchar := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_appendchar")
      return DllCall(sqlite3_str_appendchar
         ,   "Ptr", pStr
         ,   "Int", N
         ,   "Char", C
         ,   "Cdecl")
   }
   sqlite3_str_appendf(pStr, zFormat){    ; untested https://sqlite.org/c3ref/str_append.html
      static sqlite3_str_appendf := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_appendf")
      return DllCall(sqlite3_str_appendf
         ,   "Ptr", pStr
         ,   "Str", zFormat
         ,   "Cdecl")
   }
   sqlite3_str_errcode(pStr){    ; untested https://sqlite.org/c3ref/str_errcode.html
      static sqlite3_str_errcode := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_errcode")
      return DllCall(sqlite3_str_errcode
         ,   "Ptr", pStr
         ,   "Cdecl")
   }
   sqlite3_str_finish(pStr){    ; untested https://sqlite.org/c3ref/str_finish.html
      static sqlite3_str_finish := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_finish")
      return DllCall(sqlite3_str_finish
         ,   "Ptr", pStr
         ,   "Cdecl")
   }
   sqlite3_str_length(pStr){    ; untested https://sqlite.org/c3ref/str_errcode.html
      static sqlite3_str_length := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_length")
      return DllCall(sqlite3_str_length
         ,   "Ptr", pStr
         ,   "Cdecl")
   }
   sqlite3_str_new(pDb){    ; untested https://sqlite.org/c3ref/str_new.html
      static sqlite3_str_new := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_new")
      return DllCall(sqlite3_str_new
         ,   "Ptr", pDb
         ,   "Cdecl")
   }
   sqlite3_str_reset(pStr){    ; untested https://sqlite.org/c3ref/str_append.html
      static sqlite3_str_reset := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_reset")
      return DllCall(sqlite3_str_reset
         ,   "Ptr", pStr
         ,   "Cdecl")
   }
   sqlite3_str_value(pStr){    ; untested https://sqlite.org/c3ref/str_errcode.html
      static sqlite3_str_value := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_value")
      return DllCall(sqlite3_str_value
         ,   "Ptr", pStr
         ,   "Cdecl")
   }
   sqlite3_str_vappendf(pStr, zFormat, pArgs){    ; untested https://sqlite.org/c3ref/str_append.html
      static sqlite3_str_vappendf := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_str_vappendf")
      return DllCall(sqlite3_str_vappendf
         ,   "Ptr", pStr
         ,   "Str", zFormat
         ,   "Ptr", pArgs
         ,   "Cdecl")
   }
   sqlite3_strglob(zGlob, zStr){    ; untested https://sqlite.org/c3ref/strglob.html
      static sqlite3_strglob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_strglob")
      return DllCall(sqlite3_strglob
         ,   "Str", zGlob
         ,   "Str", zStr
         ,   "Cdecl")
   }
   sqlite3_stricmp(Str1, Str2){    ; untested https://sqlite.org/c3ref/stricmp.html
      static sqlite3_stricmp := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_stricmp")
      return DllCall(sqlite3_stricmp
         ,   "Str", Str1
         ,   "Str", Str2
         ,   "Cdecl")
   }
   sqlite3_strlike(zGlob, zStr, cEsc){    ; untested https://sqlite.org/c3ref/strlike.html
      static sqlite3_strlike := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_strlike")
      return DllCall(sqlite3_strlike
         ,   "Str", zGlob
         ,   "Str", zStr
         ,   "UInt", cEsc
         ,   "Cdecl")
   }
   sqlite3_strnicmp(Str1, Str2, nLen){    ; untested https://sqlite.org/c3ref/stricmp.html
      static sqlite3_strnicmp := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_strnicmp")
      return DllCall(sqlite3_strnicmp
         ,   "Str", Str1
         ,   "Str", Str2
         ,   "UInt", nLen
         ,   "Cdecl")
   }
   sqlite3_system_errno(db){    ; untested https://sqlite.org/c3ref/system_errno.html
      static sqlite3_system_errno := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_system_errno")
      return DllCall(sqlite3_system_errno
         ,   "Ptr", db
         ,   "Cdecl")
   }
   sqlite3_table_column_metadata(db, zDbName, zTableName, zColumnName, pzDataType, pzCollSeq, pNotNull, pPrimaryKey, pAutoinc){    ; untested https://sqlite.org/c3ref/table_column_metadata.html
      static sqlite3_table_column_metadata := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_table_column_metadata")
      return DllCall(sqlite3_table_column_metadata
         ,   "Ptr", db
         ,   "Str", zDbName
         ,   "Str", zTableName
         ,   "Str", zColumnName
         ,   "PtrP", pzDataType
         ,   "PtrP", pzCollSeq
         ,   "Ptr", pNotNull
         ,   "Ptr", pPrimaryKey
         ,   "Ptr", pAutoinc
         ,   "Cdecl")
   }
   sqlite3_test_control(op){    ; untested https://sqlite.org/c3ref/test_control.html
      static sqlite3_test_control := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_test_control")
      return DllCall(sqlite3_test_control
         ,   "Int", op
         ,   "Cdecl")
   }
   sqlite3_threadsafe(){    ; untested https://sqlite.org/c3ref/threadsafe.html
      static sqlite3_threadsafe := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_threadsafe")
      return DllCall(sqlite3_threadsafe
         ,   "Cdecl")
   }
   sqlite3_total_changes() {
      static sqlite3_total_changes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_total_changes")
      return DllCall(sqlite3_total_changes
         , "Ptr", this._Handle
         , "Cdecl Int")
   }
   sqlite3_total_changes64(db){    ; untested https://sqlite.org/c3ref/total_changes.html
      static sqlite3_total_changes64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_total_changes64")
      return DllCall(sqlite3_total_changes64
         ,   "Ptr", db
         ,   "Cdecl")
   }
   sqlite3_trace_v2(db, uMask, xCallback, pCtx){    ; untested https://sqlite.org/c3ref/trace_v2.html
      static sqlite3_trace_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_trace_v2")
      return DllCall(sqlite3_trace_v2
         ,   "Ptr", db
         ,   "UInt", uMask
         ,   "Ptr", xCallback
         ,   "Ptr", pCtx
         ,   "Cdecl")
   }
   sqlite3_txn_state(db, zSchema){    ; untested https://sqlite.org/c3ref/txn_state.html
      static sqlite3_txn_state := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_txn_state")
      return DllCall(sqlite3_txn_state
         ,   "Ptr", db
         ,   "Str", zSchema
         ,   "Cdecl")
   }
   sqlite3_unlock_notify(pBlocked, xNotify, pNotifyArg){    ; untested https://sqlite.org/c3ref/unlock_notify.html
      static sqlite3_unlock_notify := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_unlock_notify")
      return DllCall(sqlite3_unlock_notify
         ,   "Ptr", pBlocked
         ,   "Ptr", xNotify
         ,   "Ptr", pNotifyArg
         ,   "Cdecl")
   }
   sqlite3_update_hook(db, xCallback, pArg){    ; untested https://sqlite.org/c3ref/update_hook.html
      static sqlite3_update_hook := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_update_hook")
      return DllCall(sqlite3_update_hook
         ,   "Ptr", db
         ,   "Ptr", xCallback
         ,   "Ptr", pArg
         ,   "Cdecl")
   }
   sqlite3_uri_parameter(z, zParam) {       ;untested    https://sqlite.org/c3ref/uri_parameter.html
      static sqlite3_uri_parameter := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_uri_parameter")
      return DllCall(sqlite3_uri_parameter
         , "Ptr", z
         , "AStr", zParam
         , "Cdecl AStr")
   }
   sqlite3_uri_boolean(z, zParam, bDefault) {       ;untested    https://sqlite.org/c3ref/uri_parameter.html
      static sqlite3_uri_boolean := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_uri_boolean")
      return DllCall(sqlite3_uri_boolean
         , "Ptr", z
         , "AStr", zParam
         , "Int", bDefault
         , "Cdecl Int")
   }
   sqlite3_uri_int64(z, zParam, bDefault) {       ;untested    https://sqlite.org/c3ref/uri_parameter.html
      static sqlite3_uri_int64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_uri_int64")
      return DllCall(sqlite3_uri_int64
         , "Ptr", z
         , "AStr", zParam
         , "Int64", bDefault
         , "Cdecl Int64")
   }
   sqlite3_uri_key(z, N) {       ;untested    https://sqlite.org/c3ref/uri_parameter.html
      static sqlite3_uri_key := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_uri_key")
      return DllCall(sqlite3_uri_key
         , "Ptr", z
         , "Int", N
         , "Cdecl AStr")
   }
   sqlite3_user_data(pContext){    ; untested https://sqlite.org/c3ref/user_data.html
      static sqlite3_user_data := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_user_data")
      return DllCall(sqlite3_user_data
         ,   "Ptr", pContext
         ,   "Cdecl")
   }
   sqlite3_value_blob(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_blob := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_blob")
      return DllCall(sqlite3_value_blob
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_bytes(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_bytes := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_bytes")
      return DllCall(sqlite3_value_bytes
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_bytes16(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_bytes16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_bytes16")
      return DllCall(sqlite3_value_bytes16
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_double(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_double := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_double")
      return DllCall(sqlite3_value_double
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_dup(pValue){    ; untested https://sqlite.org/c3ref/value_dup.html
      static sqlite3_value_dup := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_dup")
      return DllCall(sqlite3_value_dup
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_encoding(pValue){    ; untested https://sqlite.org/c3ref/value_encoding.html
      static sqlite3_value_encoding := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_encoding")
      return DllCall(sqlite3_value_encoding
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_free(pValue){    ; untested https://sqlite.org/c3ref/value_dup.html
      static sqlite3_value_free := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_free")
      return DllCall(sqlite3_value_free
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_frombind(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_frombind := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_frombind")
      return DllCall(sqlite3_value_frombind
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_int(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_int := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_int")
      return DllCall(sqlite3_value_int
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_int64(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_int64 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_int64")
      return DllCall(sqlite3_value_int64
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_nochange(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_nochange := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_nochange")
      return DllCall(sqlite3_value_nochange
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_numeric_type(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_numeric_type := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_numeric_type")
      return DllCall(sqlite3_value_numeric_type
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_pointer(pValue, pType){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_pointer := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_pointer")
      return DllCall(sqlite3_value_pointer
         ,   "Ptr", pValue
         ,   "Str", pType
         ,   "Cdecl")
   }
   sqlite3_value_subtype(pValue){    ; untested https://sqlite.org/c3ref/value_subtype.html
      static sqlite3_value_subtype := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_subtype")
      return DllCall(sqlite3_value_subtype
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_text(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_text := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_text")
      return DllCall(sqlite3_value_text
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_text16(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_text16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_text16")
      return DllCall(sqlite3_value_text16
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_text16be(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_text16be := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_text16be")
      return DllCall(sqlite3_value_text16be
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_text16le(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_text16le := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_text16le")
      return DllCall(sqlite3_value_text16le
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_value_type(pValue){    ; untested https://sqlite.org/c3ref/value_blob.html
      static sqlite3_value_type := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_value_type")
      return DllCall(sqlite3_value_type
         ,   "Ptr", pValue
         ,   "Cdecl")
   }
   sqlite3_version(){    ; untested https://sqlite.org/c3ref/libversion.html
      static sqlite3_version := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_version")
      return DllCall(sqlite3_version
         ,   "Cdecl")
   }
   sqlite3_vfs_find(zVfsName){    ; untested https://sqlite.org/c3ref/vfs_find.html
      static sqlite3_vfs_find := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vfs_find")
      return DllCall(sqlite3_vfs_find
         ,   "Str", zVfsName
         ,   "Cdecl")
   }
   sqlite3_vfs_register(pVfs, makeDflt){    ; untested https://sqlite.org/c3ref/vfs_find.html
      static sqlite3_vfs_register := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vfs_register")
      return DllCall(sqlite3_vfs_register
         ,   "Ptr", pVfs
         ,   "Int", makeDflt
         ,   "Cdecl")
   }
   sqlite3_vfs_unregister(pVfs){    ; untested https://sqlite.org/c3ref/vfs_find.html
      static sqlite3_vfs_unregister := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vfs_unregister")
      return DllCall(sqlite3_vfs_unregister
         ,   "Ptr", pVfs
         ,   "Cdecl")
   }
   sqlite3_vmprintf(zFormat, va_list){    ;untested    https://sqlite.org/c3ref/mprintf.html
      static sqlite3_vmprintf := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vmprintf")
      return DllCall(sqlite3_vmprintf
         ,   "AStr", zFormat
         ,   "Ptr", va_list
         ,   "Cdecl", "Ptr")
   }
   sqlite3_vsnprintf(n, zBuf, zFormat, va_list){    ;untested    https://sqlite.org/c3ref/mprintf.html
      static sqlite3_vsnprintf := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vsnprintf")
      return DllCall(sqlite3_vsnprintf
         ,   "Int", n
         ,   "AStr", zBuf
         ,   "AStr", zFormat
         ,   "Ptr", va_list
         ,   "Cdecl", "Ptr")
   }
   sqlite3_vtab_collation(pIndexInfo, iCol){    ; untested https://sqlite.org/c3ref/vtab_collation.html
      static sqlite3_vtab_collation := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_collation")
      return DllCall(sqlite3_vtab_collation
         ,   "Ptr", pIndexInfo
         ,   "Int", iCol
         ,   "Cdecl")
   }
   sqlite3_vtab_config(pDb, op){    ; untested https://sqlite.org/c3ref/vtab_config.html
      static sqlite3_vtab_config := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_config")
      return DllCall(sqlite3_vtab_config
         ,   "Ptr", pDb
         ,   "Int", op
         ,   "Cdecl")
   }
   sqlite3_vtab_distinct(pIndexInfo){    ; untested https://sqlite.org/c3ref/vtab_distinct.html
      static sqlite3_vtab_distinct := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_distinct")
      return DllCall(sqlite3_vtab_distinct
         ,   "Ptr", pIndexInfo
         ,   "Cdecl")
   }
   sqlite3_vtab_in(pIndexInfo, iCons, bHandle){    ; untested https://sqlite.org/c3ref/vtab_in.html
      static sqlite3_vtab_in := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_in")
      return DllCall(sqlite3_vtab_in
         ,   "Ptr", pIndexInfo
         ,   "Int", iCons
         ,   "Int", bHandle
         ,   "Cdecl")
   }
   sqlite3_vtab_in_first(pVal, ppOut){    ; untested https://sqlite.org/c3ref/vtab_in_first.html
      static sqlite3_vtab_in_first := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_in_first")
      return DllCall(sqlite3_vtab_in_first
         ,   "Ptr", pVal
         ,   "Ptr*", ppOut
         ,   "Cdecl")
   }
   sqlite3_vtab_in_next(pVal, ppOut){    ; untested https://sqlite.org/c3ref/vtab_in_first.html
      static sqlite3_vtab_in_next := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_in_next")
      return DllCall(sqlite3_vtab_in_next
         ,   "Ptr", pVal
         ,   "Ptr*", ppOut
         ,   "Cdecl")
   }
   sqlite3_vtab_nochange(pContext){    ; untested https://sqlite.org/c3ref/vtab_nochange.html
      static sqlite3_vtab_nochange := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_nochange")
      return DllCall(sqlite3_vtab_nochange
         ,   "Ptr", pContext
         ,   "Cdecl")
   }
   sqlite3_vtab_on_conflict(pDb){    ; untested https://sqlite.org/c3ref/vtab_on_conflict.html
      static sqlite3_vtab_on_conflict := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_on_conflict")
      return DllCall(sqlite3_vtab_on_conflict
         ,   "Ptr", pDb
         ,   "Cdecl")
   }
   sqlite3_vtab_rhs_value(pIndexInfo, iIndex, ppVal){    ; untested https://sqlite.org/c3ref/vtab_rhs_value.html
      static sqlite3_vtab_rhs_value := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_vtab_rhs_value")
      return DllCall(sqlite3_vtab_rhs_value
         ,   "Ptr", pIndexInfo
         ,   "Int", iIndex
         ,   "PtrP", ppVal
         ,   "Cdecl")
   }
   sqlite3_wal_autocheckpoint(db, N){    ; untested https://sqlite.org/c3ref/wal_autocheckpoint.html
      static sqlite3_wal_autocheckpoint := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_wal_autocheckpoint")
      return DllCall(sqlite3_wal_autocheckpoint
         ,   "Ptr", db
         ,   "Int", N
         ,   "Cdecl")
   }
   sqlite3_wal_checkpoint(db, zDb){    ; untested https://sqlite.org/c3ref/wal_checkpoint.html
      static sqlite3_wal_checkpoint := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_wal_checkpoint")
      return DllCall(sqlite3_wal_checkpoint
         ,   "Ptr", db
         ,   "Str", zDb
         ,   "Cdecl")
   }
   sqlite3_wal_checkpoint_v2(db, zDb, eMode, pnLog, pnCkpt){    ; untested https://sqlite.org/c3ref/wal_checkpoint.html
      static sqlite3_wal_checkpoint_v2 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_wal_checkpoint_v2")
      return DllCall(sqlite3_wal_checkpoint_v2
         ,   "Ptr", db
         ,   "Str", zDb
         ,   "Int", eMode
         ,   "Ptr", pnLog
         ,   "Ptr", pnCkpt
         ,   "Cdecl")
   }
   sqlite3_wal_hook(db, xCallback, pArg){    ; untested https://sqlite.org/c3ref/wal_hook.html
      static sqlite3_wal_hook := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_wal_hook")
      return DllCall(sqlite3_wal_hook
         ,   "Ptr", db
         ,   "Ptr", xCallback
         ,   "Ptr", pArg
         ,   "Cdecl")
   }
   sqlite3_win32_set_directory(type, zValue){    ; untested https://sqlite.org/c3ref/win32_set_directory.html
      static sqlite3_win32_set_directory := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_win32_set_directory")
      return DllCall(sqlite3_win32_set_directory
         ,   "UInt", type
         ,   "Ptr", zValue
         ,   "Cdecl")
   }
   sqlite3_win32_set_directory8(type, zValue){    ; untested https://sqlite.org/c3ref/win32_set_directory.html
      static sqlite3_win32_set_directory8 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_win32_set_directory8")
      return DllCall(sqlite3_win32_set_directory8
         ,   "UInt", type
         ,   "AStr", zValue
         ,   "Cdecl")
   }
   sqlite3_win32_set_directory16(type, zValue){    ; untested https://sqlite.org/c3ref/win32_set_directory.html
      static sqlite3_win32_set_directory16 := this._getDllAddress(SQriLiteDB._SQLiteDLL, "sqlite3_win32_set_directory16")
      return DllCall(sqlite3_win32_set_directory16
         ,   "UInt", type
         ,   "Ptr", zValue
         ,   "Cdecl")
   }
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
