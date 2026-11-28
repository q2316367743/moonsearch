///|
/// Operation and wall-clock budget for a fuzz loop.
///
/// Fuzz drivers call `charge` once per iteration. The loop aborts with a
/// message naming the driver as soon as either limit is exceeded, so a
/// regression in the code under test cannot turn a bounded fuzz run into an
/// unbounded one. The limits are deliberately generous: they catch a runaway
/// loop, not a slow machine.
pub struct FuzzBudget {
  mut operations : Int64
  max_operations : Int64
  started_ms : Int64
  max_milliseconds : Int64
}

///|
/// Start a budget. `max_operations` counts `charge` calls; `max_milliseconds`
/// bounds the wall-clock time since construction.
pub fn FuzzBudget::new(
  max_operations : Int64,
  max_milliseconds : Int64,
) -> FuzzBudget {
  {
    operations: 0L,
    max_operations,
    started_ms: @env.now().reinterpret_as_int64(),
    max_milliseconds,
  }
}

///|
/// Charge one fuzz iteration. The error text is intended for `abort`.
pub fn FuzzBudget::charge(
  self : FuzzBudget,
  label : String,
) -> Result[Unit, String] {
  self.operations = self.operations + 1
  if self.operations > self.max_operations {
    return Err(
      "\{label}: fuzz operation budget exceeded (\{self.operations} > \{self.max_operations})",
    )
  }
  let elapsed = self.elapsed_milliseconds()
  if elapsed > self.max_milliseconds {
    return Err(
      "\{label}: fuzz time budget exceeded (\{elapsed} ms > \{self.max_milliseconds} ms)",
    )
  }
  Ok(())
}

///|
/// Number of iterations charged so far.
pub fn FuzzBudget::operations(self : FuzzBudget) -> Int64 {
  self.operations
}

///|
/// Wall-clock time elapsed since the budget was created.
pub fn FuzzBudget::elapsed_milliseconds(self : FuzzBudget) -> Int64 {
  @env.now().reinterpret_as_int64() - self.started_ms
}
