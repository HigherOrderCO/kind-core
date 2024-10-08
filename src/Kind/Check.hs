module Kind.Check where

import Kind.Type
import Kind.Env
import Kind.Reduce
import Kind.Equal
import Kind.Show

import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M

import Control.Monad (forM_)
import Debug.Trace

-- Type-Checking
-- -------------

infer :: Term -> Int -> Env Term
infer term dep = debug ("infer: " ++ termShower False term dep) $ go term dep where
  go (All nam inp bod) dep = do
    envSusp (Check Nothing inp Set dep)
    envSusp (Check Nothing (bod (Ann False (Var nam dep) inp)) Set (dep + 1))
    return Set

  go (App fun arg) dep = do
    ftyp <- infer fun dep
    book <- envGetBook
    fill <- envGetFill
    case reduce book fill 2 ftyp of
      (All ftyp_nam ftyp_inp ftyp_bod) -> do
        envSusp (Check Nothing arg ftyp_inp dep)
        return $ ftyp_bod arg
      otherwise -> do
        envLog (Error Nothing (Hol "function" []) ftyp (App fun arg) dep)
        envFail

  go (Ann chk val typ) dep = do
    if chk then do
      check Nothing val typ dep
    else do
      return ()
    return typ

  go (Slf nam typ bod) dep = do
    envSusp (Check Nothing (bod (Ann False (Var nam dep) typ)) Set (dep + 1))
    return Set

  go (Ins val) dep = do
    vtyp <- infer val dep
    book <- envGetBook
    fill <- envGetFill
    case reduce book fill 2 vtyp of
      (Slf vtyp_nam vtyp_typ vtyp_bod) -> do
        return $ vtyp_bod (Ins val)
      otherwise -> do
        envLog (Error Nothing (Hol "self-type" []) vtyp (Ins val) dep)
        envFail

  -- CHANGED: Updated Dat case to handle new Ctr structure with Tele
  go (Dat scp cts) dep = do
    forM_ cts $ \ (Ctr _ tele) -> do
      checkTele Nothing tele Set dep
    return Set

  go (Ref nam) dep = do
    book <- envGetBook
    case M.lookup nam book of
      Just val -> infer val dep
      Nothing  -> do
        envLog (Error Nothing (Hol "undefined_reference" []) (Hol "unknown_type" []) (Ref nam) dep)
        envFail

  go Set dep = do
    return Set

  go U32 dep = do
    return Set

  go (Num num) dep = do
    return U32

  go (Txt txt) dep = do
    return (Ref "String")

  go (Nat val) dep = do
    return (Ref "Nat")

  go (Op2 opr fst snd) dep = do
    envSusp (Check Nothing fst U32 dep)
    envSusp (Check Nothing snd U32 dep)
    return U32

  go (Swi zer suc) dep = do
    envLog (Error Nothing (Hol "type_annotation" []) (Hol "untyped_switch" []) (Swi zer suc) dep)
    envFail

  go (Let nam val bod) dep = do
    typ <- infer val dep
    infer (bod (Ann False (Var nam dep) typ)) dep

  go (Use nam val bod) dep = do
    infer (bod val) dep

  go (Con nam arg) dep = do
    envLog (Error Nothing (Hol "type_annotation" []) (Hol "untyped_constructor" []) (Con nam arg) dep)
    envFail

  go (Mat cse) dep = do
    envLog (Error Nothing (Hol "type_annotation" []) (Hol "untyped_match" []) (Mat cse) dep)
    envFail

  go (Lam nam bod) dep = do
    envLog (Error Nothing (Hol "type_annotation" []) (Hol "untyped_lambda" []) (Lam nam bod) dep)
    envFail

  go (Hol nam ctx) dep = do
    envLog (Error Nothing (Hol "type_annotation" []) (Hol "untyped_hole" []) (Hol nam ctx) dep)
    envFail

  go (Met uid spn) dep = do
    envLog (Error Nothing (Hol "type_annotation" []) (Hol "untyped_meta" []) (Met uid spn) dep)
    envFail

  go (Var nam idx) dep = do
    envLog (Error Nothing (Hol "type_annotation" []) (Hol "untyped_variable" []) (Var nam idx) dep)
    envFail

  go (Src src val) dep = do
    infer val dep

check :: Maybe Cod -> Term -> Term -> Int -> Env ()
check src val typ dep = debug ("check: " ++ termShower True val dep ++ "\n    :: " ++ termShower True typ dep) $ go src val typ dep where
  go src (Lam nam bod) typx dep = do
    book <- envGetBook
    fill <- envGetFill
    case reduce book fill 2 typx of
      (All typ_nam typ_inp typ_bod) -> do
        let ann = Ann False (Var nam dep) typ_inp
        check Nothing (bod ann) (typ_bod ann) (dep + 1)
      otherwise -> do
        infer (Lam nam bod) dep
        return ()

  go src (Ins val) typx dep = do
    book <- envGetBook
    fill <- envGetFill
    case reduce book fill 2 typx of
      Slf typ_nam typ_typ typ_bod -> do
        check Nothing val (typ_bod (Ins val)) dep
      _ -> do
        infer (Ins val) dep
        return ()

  -- CHANGED: Updated Con case to handle new Ctr structure with Tele
  go src val@(Con nam arg) typx dep = do
    book <- envGetBook
    fill <- envGetFill
    case reduce book fill 2 typx of
      (Dat adt_scp adt_cts) -> do
        case lookup nam (map (\(Ctr cnm tele) -> (cnm, tele)) adt_cts) of
          Just tele -> do
            checkConAgainstTele Nothing arg tele dep
            cmp src val typx typx dep
          Nothing -> do
            envLog (Error Nothing (Hol ("constructor_not_found:"++nam) []) (Hol "unknown_type" []) (Con nam arg) dep)
            envFail
      _ -> do
        infer (Con nam arg) dep
        return ()

  -- CHANGED: Updated Mat case to handle new Ctr structure with Tele
  go src (Mat cse) typx dep = do
    book <- envGetBook
    fill <- envGetFill
    case reduce book fill 2 typx of
      (All typ_nam typ_inp typ_bod) -> do
        case reduce book fill 2 typ_inp of
          (Dat adt_scp adt_cts) -> do
            let adt_cts_map = M.fromList (map (\ (Ctr cnm tele) -> (cnm, tele)) adt_cts)
            forM_ cse $ \ (cnm, cbod) -> do
              case M.lookup cnm adt_cts_map of
                Just tele -> do
                  let a_r = teleToTerm tele dep
                  let eqs = extractEqualities (reduce book fill 2 typ_inp) (reduce book fill 2 (snd a_r)) dep
                  let rt0 = teleToType tele (typ_bod (Ann False (Con cnm (fst a_r)) typ_inp)) dep
                  let rt1 = foldl' (\ ty (i,t) -> subst i t ty) rt0 eqs
                  check Nothing cbod rt1 dep
                Nothing -> do
                  envLog (Error Nothing (Hol ("constructor_not_found:"++cnm) []) (Hol "unknown_type" []) (Mat cse) dep)
                  envFail
          _ -> do
            infer (Mat cse) dep
            return ()
      _ -> do
        infer (Mat cse) dep
        return ()

  go src (Swi zer suc) typx dep = do
    book <- envGetBook
    fill <- envGetFill
    case reduce book fill 2 typx of
      (All typ_nam typ_inp typ_bod) -> do
        case reduce book fill 2 typ_inp of
          U32 -> do
            -- Check zero case
            let zerAnn = Ann False (Num 0) U32
            check Nothing zer (typ_bod zerAnn) dep
            -- Check successor case
            let n = Var "n" dep
            let sucAnn = Ann False n U32
            let sucTyp = All "n" U32 (\x -> typ_bod (Op2 ADD (Num 1) x))
            check Nothing suc sucTyp dep
          _ -> do
            infer (Swi zer suc) dep
            return ()
      _ -> do
        infer (Swi zer suc) dep
        return ()

  go src (Let nam val bod) typx dep = do
    typ <- infer val dep
    check Nothing (bod (Ann False (Var nam dep) typ)) typx dep

  go src (Use nam val bod) typx dep = do
    check Nothing (bod val) typx dep

  go src (Hol nam ctx) typx dep = do
    envLog (Found nam typx ctx dep)
    return ()

  go src (Met uid spn) typx dep = do
    return ()

  go src (Ann chk val typ) typx dep = do
    cmp src val typ typx dep
    if chk then do
      check src val typ dep
    else do
      return ()

  go _ (Src src val) typx dep = do
    check (Just src) val typx dep

  go src term typx dep = do
    infer <- infer term dep
    cmp src term typx infer dep

  cmp src term expected detected dep = do
    equal <- equal expected detected dep
    if equal then do
      susp <- envTakeSusp
      forM_ susp $ \ (Check src val typ dep) -> do
        go src val typ dep
      return ()
    else do
      envLog (Error src expected detected term dep)
      envFail

-- CHANGED: Added checkTele function
checkTele :: Maybe Cod -> Tele -> Term -> Int -> Env ()
checkTele src tele typ dep = case tele of
  TRet term -> check src term typ dep
  TExt nam inp bod -> do
    check src inp Set dep
    checkTele src (bod (Ann False (Var nam dep) inp)) typ (dep + 1)

-- CHANGED: Added checkConAgainstTele function
checkConAgainstTele :: Maybe Cod -> [Term] -> Tele -> Int -> Env ()
checkConAgainstTele src [] (TRet _) _ = return ()
checkConAgainstTele src (arg:args) (TExt nam inp bod) dep = do
  check src arg inp dep
  checkConAgainstTele src args (bod arg) dep
checkConAgainstTele src _ _ dep = do
  envLog (Error src (Hol "constructor_arity_mismatch" []) (Hol "unknown_type" []) (Hol "constructor" []) dep)
  envFail

-- CHANGED: ....
teleToType :: Tele -> Term -> Int -> Term
teleToType (TRet _)           ret _   = ret
teleToType (TExt nam inp bod) ret dep = All nam inp (\x -> teleToType (bod x) ret (dep + 1))

-- CHANGED: Helper function to extract both arguments and return type from a telescope
teleToTerm :: Tele -> Int -> ([Term], Term)
teleToTerm tele dep = go tele [] dep where
  go (TRet ret)         args _   = (reverse args, ret)
  go (TExt nam inp bod) args dep = go (bod (Var nam dep)) ((Var nam dep) : args) (dep + 1)

-- CHANGED: ...
extractEqualities :: Term -> Term -> Int -> [(Int, Term)]
extractEqualities (Dat as _) (Dat bs _) dep = zipWith go as bs where
  go (Var _ i) v = (i, v)
  go (Src _ i) v = go i v
  go a         v = trace ("Unexpected term: " ++ termShower True a dep) (0, v)
extractEqualities a b dep = trace ("Unexpected terms: " ++ termShower True a dep ++ " and " ++ termShower True b dep) []

doCheck :: Term -> Env ()
doCheck (Ann _ val typ) = check Nothing val typ 0 >> return ()
doCheck (Src _ val)     = doCheck val
doCheck (Ref nam)       = doCheckRef nam
doCheck term            = infer term 0 >> return ()

doCheckRef :: String -> Env ()
doCheckRef nam = do
  book <- envGetBook
  case M.lookup nam book of
    Just val -> doCheck val
    Nothing  -> envLog (Error Nothing (Hol "undefined_reference" []) (Hol "unknown_type" []) (Ref nam) 0) >> envFail
