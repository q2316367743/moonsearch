///|
test "operation budget counts charges and reports exhaustion" {
  let budget = @testkit.FuzzBudget::new(2L, 60_000L)
  assert_eq(budget.operations(), 0L)
  assert_true(budget.charge("fuzz") is Ok(_))
  assert_true(budget.charge("fuzz") is Ok(_))
  match budget.charge("fuzz") {
    Ok(_) => abort("the third charge must exceed a two-operation budget")
    Err(message) => {
      assert_true(message.contains("operation budget exceeded"))
      assert_true(message.contains("fuzz"))
    }
  }
  assert_eq(budget.operations(), 3L)
}

///|
test "time budget is reported separately from the operation budget" {
  let budget = @testkit.FuzzBudget::new(100L, -1L)
  match budget.charge("slow fuzz") {
    Ok(_) => abort("a negative time budget must fail immediately")
    Err(message) => {
      assert_true(message.contains("time budget exceeded"))
      assert_true(message.contains("slow fuzz"))
    }
  }
  assert_eq(budget.operations(), 1L)
}
