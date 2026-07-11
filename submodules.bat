@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================
REM SecLeap 安全能力子模块统一管理脚本
REM
REM 用法:
REM   submodules.bat add      添加缺失子模块并修复损坏条目
REM   submodules.bat update   初始化并更新已注册子模块
REM   submodules.bat all      先添加/修复，再更新（默认）
REM   submodules.bat status   查看父仓库与子模块状态
REM
REM 相比原版的改进:
REM   1. 单个仓库失败不再中断整个流程，全部处理完后统一汇总失败列表
REM   2. 仓库清单改为一行式列表，新增/删除仓库无需改多处代码
REM   3. 推送父仓库前自动 fetch，推送被拒时自动 rebase 后重试一次
REM   4. 远程协议前缀可配置（REMOTE_PROTO），便于切换 SSH/HTTPS
REM   5. 新增 -h/--help 用法说明
REM ============================================================

set "ORG=SecLeap"
set "BASE_DIR=repositories"
set "DEFAULT_BRANCH=main"
set "REMOTE_PROTO=git@github.com:"
set "MODE=%~1"

if "%MODE%"=="" set "MODE=all"
if /I "%MODE%"=="-h" set "MODE=help"
if /I "%MODE%"=="--help" set "MODE=help"
if /I "%MODE%"=="/?" set "MODE=help"
if /I "%MODE%"=="help" goto USAGE

if /I not "%MODE%"=="add" if /I not "%MODE%"=="update" if /I not "%MODE%"=="all" if /I not "%MODE%"=="status" (
    echo [ERROR] 未知模式: %MODE%
    goto USAGE_ERR
)

REM ------------------------------------------------------------
REM 仓库清单（新增/删除仓库只需改这一行）
REM ------------------------------------------------------------
set "REPOS=security-monitoring threat-tracing-forensics incident-response offensive-security vulnerability-management security-operations asset-exposure-management security-engineering-delivery"

REM ------------------------------------------------------------
REM 环境检查
REM ------------------------------------------------------------
git --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未检测到 Git，请确认已安装并加入 PATH。
    exit /b 1
)

git rev-parse --show-toplevel >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 当前目录不是 Git 仓库。
    echo [INFO] 请在 security-capability 仓库根目录下运行本脚本。
    exit /b 1
)

for /f "delims=" %%I in ('git rev-parse --show-toplevel') do set "ROOT_DIR=%%I"
cd /d "%ROOT_DIR%"

echo ============================================================
echo SecLeap 子模块管理器
echo ============================================================
echo [INFO] 根目录 : %ROOT_DIR%
echo [INFO] 组织   : %ORG%
echo [INFO] 模式   : %MODE%
echo [INFO] 分支   : %DEFAULT_BRANCH%
echo ============================================================
echo.

if not exist "%BASE_DIR%" mkdir "%BASE_DIR%"

set "ADD_OK=0"
set "ADD_FAIL=0"
set "ADD_FAIL_LIST="
set "UPD_OK=0"
set "UPD_FAIL=0"
set "UPD_FAIL_LIST="

if /I "%MODE%"=="status" (
    call :SHOW_STATUS
    exit /b 0
)

if /I "%MODE%"=="add" (
    call :ADD_ALL
    call :COMMIT_PARENT
    call :SHOW_SUMMARY
    goto EOF_WITH_CODE
)

if /I "%MODE%"=="update" (
    call :UPDATE_ALL
    call :COMMIT_PARENT
    call :SHOW_SUMMARY
    goto EOF_WITH_CODE
)

REM all
call :ADD_ALL
call :UPDATE_ALL
call :COMMIT_PARENT
call :SHOW_SUMMARY

:EOF_WITH_CODE
if %ADD_FAIL% GTR 0 exit /b 1
if %UPD_FAIL% GTR 0 exit /b 1
exit /b 0

REM ============================================================
REM 添加/修复所有仓库（单个失败不中断整体流程）
REM ============================================================

:ADD_ALL
echo.
echo ============================================================
echo 添加/修复子模块
echo ============================================================

for %%V in (%REPOS%) do (
    call :ENSURE_ONE "%%V"
    if errorlevel 1 (
        set /a ADD_FAIL+=1
        set "ADD_FAIL_LIST=!ADD_FAIL_LIST! %%V"
    ) else (
        set /a ADD_OK+=1
    )
)
exit /b 0

REM ============================================================
REM 确保单个仓库被正确注册为子模块
REM ============================================================

:ENSURE_ONE
set "REPO=%~1"
set "REPO_URL=%REMOTE_PROTO%%ORG%/%REPO%.git"
set "REPO_PATH=%BASE_DIR%/%REPO%"
set "REPO_PATH_WIN=%BASE_DIR%\%REPO%"
set "MODULE_PATH=.git\modules\%BASE_DIR%\%REPO%"
set "REGISTERED="
set "INDEXED="
set "REMOTE_HEAD="

echo.
echo ------------------------------------------------------------
echo [检查] %ORG%/%REPO%
echo ------------------------------------------------------------

REM 1. 验证对远程仓库的 SSH 访问权限
git ls-remote "%REPO_URL%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 远程仓库不存在或 SSH 账号无权限访问:
    echo         %REPO_URL%
    exit /b 1
)

REM 2. 若远程仓库没有任何提交，先初始化一个空仓库
for /f "tokens=1" %%H in ('git ls-remote "%REPO_URL%" HEAD 2^>nul') do set "REMOTE_HEAD=%%H"

if not defined REMOTE_HEAD (
    echo [WARN] 远程仓库尚无提交，正在初始化。
    call :INITIALIZE_EMPTY_REPO "%REPO%" "%REPO_URL%"
    if errorlevel 1 exit /b 1
)

REM 3. 判断该路径是否已在 .gitmodules 中注册
if exist ".gitmodules" (
    for /f "tokens=2" %%P in ('git config -f .gitmodules --get-regexp "^submodule\..*\.path$" 2^>nul') do (
        if /I "%%P"=="%REPO_PATH%" set "REGISTERED=1"
    )
)

REM 4. 判断该路径是否已存在于 Git 索引中
git ls-files --stage -- "%REPO_PATH%" | findstr /R "^160000 " >nul 2>&1
if not errorlevel 1 set "INDEXED=1"

REM 5. 已正确注册: 按需初始化，跳过 add
if defined REGISTERED (
    echo [SKIP] 已在 .gitmodules 中注册。

    git submodule sync -- "%REPO_PATH%" >nul 2>&1
    git submodule update --init --recursive -- "%REPO_PATH%"
    if errorlevel 1 (
        echo [ERROR] 已注册子模块初始化失败: %REPO_PATH%
        exit /b 1
    )

    echo [OK] 已注册子模块初始化完成: %REPO%
    exit /b 0
)

REM 6. 索引中存在但未注册: 清除陈旧的 gitlink 条目
if defined INDEXED (
    echo [REPAIR] Git 索引中存在陈旧子模块条目，正在移除: %REPO_PATH%

    git rm --cached -f --ignore-unmatch -- "%REPO_PATH%" >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] 移除陈旧索引条目失败: %REPO_PATH%
        exit /b 1
    )
)

REM 7. 仅清理未注册的残留工作区/元数据
if exist "%REPO_PATH_WIN%" (
    echo [CLEAN] 移除未注册的工作区残留: %REPO_PATH_WIN%
    rmdir /s /q "%REPO_PATH_WIN%"
)

if exist "%MODULE_PATH%" (
    echo [CLEAN] 移除未注册的 Git 元数据: %MODULE_PATH%
    rmdir /s /q "%MODULE_PATH%"
)

git config --remove-section "submodule.%REPO_PATH%" >nul 2>&1
git config --remove-section "submodule.%REPO%" >nul 2>&1

REM 8. 添加缺失的子模块
echo [ADD] %REPO_URL%
git submodule add -b "%DEFAULT_BRANCH%" "%REPO_URL%" "%REPO_PATH%"
if errorlevel 1 (
    echo [ERROR] 添加子模块失败: %REPO%
    echo [INFO] 可通过以下命令排查:
    echo        git status
    echo        git ls-files --stage -- %REPO_PATH%
    exit /b 1
)

git config -f .gitmodules "submodule.%REPO_PATH%.branch" "%DEFAULT_BRANCH%"

echo [OK] 子模块添加成功: %REPO%
exit /b 0

REM ============================================================
REM 初始化一个空的远程仓库
REM ============================================================

:INITIALIZE_EMPTY_REPO
set "INIT_REPO=%~1"
set "INIT_URL=%~2"
set "TEMP_DIR=%TEMP%\secleap-init-%INIT_REPO%-%RANDOM%-%RANDOM%"

if exist "%TEMP_DIR%" rmdir /s /q "%TEMP_DIR%"
mkdir "%TEMP_DIR%"
if errorlevel 1 (
    echo [ERROR] 无法创建临时目录: %TEMP_DIR%
    exit /b 1
)

pushd "%TEMP_DIR%"

git init -b "%DEFAULT_BRANCH%" >nul 2>&1
if errorlevel 1 (
    git init >nul 2>&1
    git checkout -b "%DEFAULT_BRANCH%" >nul 2>&1
)

(
    echo # %INIT_REPO%
    echo.
    echo SecLeap cybersecurity capability repository.
) > README.md

git add README.md
git commit -m "docs: initialize repository" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 创建初始提交失败。
    echo [INFO] 请先配置 Git 身份:
    echo        git config --global user.name "Your Name"
    echo        git config --global user.email "you@example.com"
    popd
    rmdir /s /q "%TEMP_DIR%" >nul 2>&1
    exit /b 1
)

git remote add origin "%INIT_URL%"
git push -u origin "%DEFAULT_BRANCH%"
if errorlevel 1 (
    echo [ERROR] 推送初始提交失败: %INIT_URL%
    popd
    rmdir /s /q "%TEMP_DIR%" >nul 2>&1
    exit /b 1
)

popd
rmdir /s /q "%TEMP_DIR%" >nul 2>&1

echo [OK] 空仓库初始化完成: %INIT_REPO%
exit /b 0

REM ============================================================
REM 更新所有已注册子模块（单个失败不中断整体流程）
REM ============================================================

:UPDATE_ALL
echo.
echo ============================================================
echo 同步子模块
echo ============================================================

if not exist ".gitmodules" (
    echo [WARN] 未找到 .gitmodules 文件，跳过更新。
    exit /b 0
)

git submodule sync --recursive
if errorlevel 1 echo [WARN] 子模块 URL 同步失败，将继续逐个尝试更新。

git submodule update --init --recursive
if errorlevel 1 echo [WARN] 批量初始化子模块失败，将继续逐个尝试更新。

for %%V in (%REPOS%) do (
    call :UPDATE_ONE "%%V"
    if errorlevel 1 (
        set /a UPD_FAIL+=1
        set "UPD_FAIL_LIST=!UPD_FAIL_LIST! %%V"
    ) else (
        set /a UPD_OK+=1
    )
)
exit /b 0

REM ============================================================
REM 更新单个已注册子模块
REM ============================================================

:UPDATE_ONE
set "REPO=%~1"
set "REPO_PATH=%BASE_DIR%/%REPO%"
set "REPO_PATH_WIN=%BASE_DIR%\%REPO%"
set "REGISTERED="

echo.
echo ------------------------------------------------------------
echo [更新] %REPO%
echo ------------------------------------------------------------

if exist ".gitmodules" (
    for /f "tokens=2" %%P in ('git config -f .gitmodules --get-regexp "^submodule\..*\.path$" 2^>nul') do (
        if /I "%%P"=="%REPO_PATH%" set "REGISTERED=1"
    )
)

if not defined REGISTERED (
    echo [SKIP] 未注册为子模块。
    exit /b 0
)

if not exist "%REPO_PATH_WIN%\.git" (
    echo [INIT] 初始化: %REPO_PATH%
    git submodule update --init --recursive -- "%REPO_PATH%"
    if errorlevel 1 (
        echo [ERROR] 初始化失败: %REPO%
        exit /b 1
    )
)

REM 子仓库存在未提交改动时拒绝覆盖
git -C "%REPO_PATH_WIN%" diff --quiet
if errorlevel 1 (
    echo [ERROR] 存在未提交的工作区改动: %REPO_PATH%
    echo [INFO] 请先提交或暂存后再更新。
    exit /b 1
)

git -C "%REPO_PATH_WIN%" diff --cached --quiet
if errorlevel 1 (
    echo [ERROR] 存在已暂存但未提交的改动: %REPO_PATH%
    echo [INFO] 请先提交或暂存后再更新。
    exit /b 1
)

git -C "%REPO_PATH_WIN%" fetch origin
if errorlevel 1 (
    echo [ERROR] 拉取远程失败: %REPO%
    exit /b 1
)

git -C "%REPO_PATH_WIN%" show-ref --verify --quiet "refs/remotes/origin/%DEFAULT_BRANCH%"
if errorlevel 1 (
    echo [ERROR] 远程分支 origin/%DEFAULT_BRANCH% 不存在: %REPO%
    exit /b 1
)

git -C "%REPO_PATH_WIN%" show-ref --verify --quiet "refs/heads/%DEFAULT_BRANCH%"
if errorlevel 1 (
    git -C "%REPO_PATH_WIN%" checkout -b "%DEFAULT_BRANCH%" "origin/%DEFAULT_BRANCH%"
) else (
    git -C "%REPO_PATH_WIN%" checkout "%DEFAULT_BRANCH%"
)

if errorlevel 1 (
    echo [ERROR] 检出 %DEFAULT_BRANCH% 失败: %REPO%
    exit /b 1
)

git -C "%REPO_PATH_WIN%" pull --ff-only origin "%DEFAULT_BRANCH%"
if errorlevel 1 (
    echo [ERROR] 快进更新失败: %REPO%
    echo [INFO] 本地分支可能已与 origin/%DEFAULT_BRANCH% 分叉。
    exit /b 1
)

echo [OK] 更新完成: %REPO%
exit /b 0

REM ============================================================
REM 提交父仓库的子模块引用变更并推送
REM ============================================================

:COMMIT_PARENT
echo.
echo ============================================================
echo 更新父仓库子模块引用
echo ============================================================

if exist ".gitmodules" git add .gitmodules
git add "%BASE_DIR%"

git diff --cached --quiet
if not errorlevel 1 (
    echo [INFO] 父仓库无子模块引用变更。
    exit /b 0
)

git commit -m "chore: synchronize security capability submodules"
if errorlevel 1 (
    echo [ERROR] 父仓库提交失败。
    exit /b 1
)

REM 推送前先 fetch 远端，降低非快进推送失败概率
git fetch origin "%DEFAULT_BRANCH%" >nul 2>&1

git push origin "%DEFAULT_BRANCH%"
if errorlevel 1 (
    echo [WARN] 直接推送被拒绝，尝试 rebase 后重试一次。
    git pull --rebase origin "%DEFAULT_BRANCH%"
    if errorlevel 1 (
        echo [ERROR] Rebase 失败，存在冲突，请手动解决后执行:
        echo         git push origin %DEFAULT_BRANCH%
        exit /b 1
    )
    git push origin "%DEFAULT_BRANCH%"
    if errorlevel 1 (
        echo [ERROR] 重试推送仍然失败，请手动执行:
        echo         git push origin %DEFAULT_BRANCH%
        exit /b 1
    )
)

echo [OK] 父仓库子模块引用推送成功。
exit /b 0

REM ============================================================
REM 显示状态
REM ============================================================

:SHOW_STATUS
echo.
echo ============================================================
echo 父仓库状态
echo ============================================================
git status --short

echo.
echo ============================================================
echo 子模块状态
echo ============================================================
if exist ".gitmodules" (
    git submodule status --recursive
) else (
    echo [INFO] 未找到 .gitmodules 文件。
)

echo.
echo ============================================================
echo 已注册子模块路径
echo ============================================================
if exist ".gitmodules" (
    git config -f .gitmodules --get-regexp "^submodule\..*\.path$"
) else (
    echo [INFO] 暂无已注册子模块。
)

exit /b 0

REM ============================================================
REM 执行结果汇总
REM ============================================================

:SHOW_SUMMARY
echo.
echo ============================================================
echo 执行汇总
echo ============================================================
echo [ADD]    成功: %ADD_OK%   失败: %ADD_FAIL%
if %ADD_FAIL% GTR 0 echo          失败仓库:%ADD_FAIL_LIST%
echo [UPDATE] 成功: %UPD_OK%   失败: %UPD_FAIL%
if %UPD_FAIL% GTR 0 echo          失败仓库:%UPD_FAIL_LIST%
echo ============================================================
echo.
echo 命令说明:
echo   %~nx0 add       添加缺失子模块并修复损坏条目
echo   %~nx0 update    初始化并更新已注册子模块
echo   %~nx0 all       先添加/修复，再更新（默认）
echo   %~nx0 status    查看父仓库与子模块状态
echo.
exit /b 0

REM ============================================================
REM 用法说明
REM ============================================================

:USAGE
echo ============================================================
echo SecLeap 子模块管理器 - 用法
echo ============================================================
echo   %~nx0 add       添加缺失子模块并修复损坏条目
echo   %~nx0 update    初始化并更新已注册子模块
echo   %~nx0 all       先添加/修复，再更新（默认）
echo   %~nx0 status    查看父仓库与子模块状态
exit /b 0

:USAGE_ERR
call :USAGE
exit /b 1
