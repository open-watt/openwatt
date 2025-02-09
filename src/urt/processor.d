module urt.processor;


// Different arch may define this differently...
// question is; is it worth a branch to avoid a redundant store?
enum bool BranchMoreExpensiveThanStore = false;
