/*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*/

/* Unit test system for Ficus */
import Sys

exception TestAssertError
exception TestFailure: string

type test_options_t =
{
    filter: string = ""
}

type test_info_t =
{
    name: string,
    f: void->void
}

type test_rng_t =
{
    state: uint64 ref
}

fun test_rng_int(rng: test_rng_t, a: int, b: int)
{
    val s = *rng.state
    val s = (s :> uint32) * 4197999714u64 + (s >> 32)
    val (a, b) = (min(a, b), max(a, b))
    val diff = b - a
    val x = (s :> uint32) % diff + a
    *rng.state = s
    (x :> int)
}

fun test_rng_copy(rng: test_rng_t)
{
    test_rng_t {state = ref(*rng.state)}
}

type test_state_t =
{
    currstatus: bool,
    rng: test_rng_t
}

var g_test_all_registered = ([]: test_info_t list)
val g_test_rng0 = test_rng_t {state=ref(0x123456789u64)}

fun test_init_state() = test_state_t {
    currstatus=true,
    rng=test_rng_copy(g_test_rng0)
}

fun test_init_state_before_test() = test_init_state()

var g_test_state = test_init_state()

fun TEST(name: string, f: void->void)
{
    g_test_all_registered = (test_info_t {name=name, f=f}) :: g_test_all_registered
}

fun test_nomsg(): string = ""
fun test_msg(s: string) = (fun() {s})

fun ASSERT(c: bool, msg: void->string)
{
    if(!c) {
        val m = msg()
        if (m == "") {
            println(f"Assertion failed.")
        } else {
            println(f"Assertion failed: {m}")
        }
        throw TestAssertError
    }
}

fun ASSERT(c: bool) = ASSERT(c, test_msg(""))

fun test_failed_assert_cmp(a: 't, b: 't, op: string)
{
    print("Error: Assertion failed:\nActual:")
    println(a)
    print(f"Expected: {op}")
    println(b)
    throw TestAssertError
}

fun ASSERT_EQ(a: 't, b: 't) = if a == b {} else {test_failed_assert_cmp(a, b, "")}
fun ASSERT_NE(a: 't, b: 't) = if a != b {} else {test_failed_assert_cmp(a, b, "!=")}
fun ASSERT_LT(a: 't, b: 't) = if a < b {} else {test_failed_assert_cmp(a, b, "<")}
fun ASSERT_LE(a: 't, b: 't) = if a <= b {} else {test_failed_assert_cmp(a, b, "<=")}
fun ASSERT_GT(a: 't, b: 't) = if a > b {} else {test_failed_assert_cmp(a, b, ">")}
fun ASSERT_GE(a: 't, b: 't) = if a >= b {} else {test_failed_assert_cmp(a, b, ">=")}

fun ASSERT_NEAR(a: 't, b: 't, eps: 't) =
    if b - eps <= a <= b + eps {} else {
        println("Assertion failed.\nActual: ")
        println(a)
        print("Expected: ")
        print(b)
        println(f" ±{eps}")
        throw TestAssertError
    }

fun EXPECT(c: bool, msg: void->string)
{
    if(!c) {
        val m = msg()
        if (m == "") {
            println(f"Error. EXPECT(...) is not satisfied.")
        } else {
            println(f"Error: {m}.")
        }
        g_test_state.currstatus = false
    }
}

fun EXPECT(c: bool) = EXPECT(c, test_nomsg)

fun test_failed_expect_cmp(a: 't, b: 't, op: string)
{
    print("Actual: ")
    println(a)
    print(f"Expected: {op}")
    println(b)
    g_test_state.currstatus = false
}

fun test_failed_expect_near(a: 't, b: 't, eps: 't)
{
    print("Actual: ")
    println(a)
    print(f"Expected: ")
    print(b)
    println(f" ±{eps}")
    g_test_state.currstatus = false
}

fun EXPECT_EQ(a: 't, b: 't) = if a == b {} else {test_failed_expect_cmp(a, b, "")}
fun EXPECT_NE(a: 't, b: 't) = if a != b {} else {test_failed_expect_cmp(a, b, "!=")}
fun EXPECT_LT(a: 't, b: 't) = if a < b {} else {test_failed_expect_cmp(a, b, "<")}
fun EXPECT_LE(a: 't, b: 't) = if a <= b {} else {test_failed_expect_cmp(a, b, "<=")}
fun EXPECT_GT(a: 't, b: 't) = if a > b {} else {test_failed_expect_cmp(a, b, ">")}
fun EXPECT_GE(a: 't, b: 't) = if a >= b {} else {test_failed_expect_cmp(a, b, ">=")}

fun EXPECT_NEAR(a: 't, b: 't, eps: 't) =
    if b - eps <= a <= b + eps {} else {test_failed_expect_near(a, b, eps)}

fun EXPECT_NEAR(a: 't [+], b: 't [+], eps: 't) =
    ignore(fold r = true for ai@idx <- a, bi <- b {
        if !(bi - eps <= ai <= bi + eps) {
            test_failed_expect_near(ai, bi, eps)
            break with false
        }
        r
    })

fun EXPECT_NEAR(a: 't list, b: 't list, eps: 't) =
    ignore(fold r = true for ai@idx <- a, bi <- b {
        if !(bi - eps <= ai <= bi + eps) {
            test_failed_expect_near(ai, bi, eps)
            break with false
        }
        r
    })

fun test_duration2str(ts_diff: double)
{
    val ts_rdiff = round(ts_diff)
    if ts_rdiff < 1 {"<1 ms"} else {string(ts_rdiff) + " ms"}
}

fun test_run_all(opts: test_options_t)
{
    val filter = opts.filter
    val (inverse_test, filter) = if filter.startswith("^") {(true, filter[1:])} else {(false, filter)}
    val (startswithstar, filter) = if filter.startswith("*") {(true, filter[1:])} else {(false, filter)}
    val (endswithstar, filter) = if filter.endswith("*") {(true, filter[:.-1])} else {(false, filter)}
    if filter.find("*") >= 0 {
        throw TestFailure("test filter with '*' inside is currently unsupported")
    }
    val ts_scale = 1000./Sys.getTickFrequency()
    var nexecuted = 0
    val ts0_start = Sys.getTickCount()
    val fold failed = ([]: string list) for t <- g_test_all_registered.rev() {
        val name = t.name
        val matches =
            filter == "" ||
            name == filter ||
            (startswithstar && name.endswith(filter)) ||
            (endswithstar && name.startswith(filter)) ||
            (startswithstar && endswithstar && name.find(filter) != -1)
        if (!matches ^ inverse_test) {failed}
        else {
            nexecuted += 1
            println(f"\33[32;1m[ RUN      ]\33[0m {name}")
            g_test_state = test_init_state_before_test()
            val ts_start = Sys.getTickCount()
            try {
                t.f()
            } catch {
            | TestAssertError =>
                g_test_state.currstatus = false
            | e =>
                println(f"Exception {e} occured.")
                g_test_state.currstatus = false
            }
            val ts_end = Sys.getTickCount()
            val ok = g_test_state.currstatus
            val ok_fail = if ok {"\33[32;1m[       OK ]\33[0m"}
                          else {"\33[31;1m[     FAIL ]\33[0m"}
            val ts_diff_str = test_duration2str((ts_end - ts_start)*ts_scale)
            println(f"{ok_fail} {name} ({ts_diff_str})\n")
            if ok {failed} else {name :: failed}
        }
    }
    val ts0_end = Sys.getTickCount()
    val ts0_diff_str = test_duration2str((ts0_end - ts0_start)*ts_scale)
    val nfailed = failed.length()
    val npassed = nexecuted - nfailed
    println(f"[==========] {nexecuted} test(s) ran ({ts0_diff_str})")
    println(f"\33[32;1m[  PASSED  ]\33[0m {npassed} test(s)")
    if nfailed > 0 {
        println(f"\33[31;1m[  FAILED ]\33[0m {nfailed} test(s):")
        for i <- failed.rev() {println(i)}
    }
}

fun test_parse_options(args: string list) {
    var options = test_options_t {}
    fun print_help() {
        println("Ficus unit tests.
The following options are available:
-f filter - specifies glob-like regular expression for the names of tests to run.
            May include '*' in the beginning of in the end.
            '^' in the beginning means that the filter should be inversed.
-l - list the available tests.
-h or -help or --help - prints this information.")
    }
    fun parse(args: string list) {
        | "-f" :: filter :: rest =>
            options.filter = filter
            parse(rest)
        | "-l" :: _ =>
            for t <- g_test_all_registered.rev() {
                println(t.name)
            }
            (false, options)
        | "-h" :: _ | "-help" :: _ | "--help" :: _ =>
            print_help()
            (false, options)
        | [] => (true, options)
        | o :: _ =>
            println("Invalid option\n")
            print_help()
            (false, options)
    }
    parse(args)
}