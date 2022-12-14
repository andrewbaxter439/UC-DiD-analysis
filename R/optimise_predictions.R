library(tidyverse)
library(tidymodels)
library(furrr)
library(data.table)

# importing ukmod data ----------------------------------------------------------

input_parts <-
  tibble(
    file = file.path("data/ukmod_out", dir("data/ukmod_out")),
    year_policy = str_extract(file, "(?<=uk_)\\w*(?=\\.txt)")
  ) |>
  mutate(data = future_map(file, fread))

full_pred_data <- input_parts |>
  select(-file) |>
  separate(year_policy,
           into = c("year", "policy"),
           sep = "_") |>
  pivot_wider(names_from = policy, values_from = data) |>
  mutate(
    UCAon = map(
      UCAon,
      transmute,
      uc_income = bho_s + bmu_s + boamt_s + boamtmm_s + boamtxp_s + bsauc_s - brduc_s,
      uc_receipt = as.numeric(bsauc_s - brduc_s > 0),
      idperson = idperson
    ),
    LBAon = map(
      LBAon,
      mutate,
      lba_income = bho_s + bmu_s + boamt_s + boamtmm_s + boamtxp_s + bfamt_s + bsadi_s + bsa_s + bwkmt_s - brd_s
    )
  ) |>
  mutate(comb_data = map2(LBAon, UCAon, left_join, by = "idperson"),
         .keep = "unused") |>
  unnest(comb_data) |>
  arrange(year, idperson)

rm(input_parts)

full_pred_data <- full_pred_data |>
  group_by(year, idhh) |>
  mutate(children = sum(dag < 16)) |>
  ungroup()


ukmod_tidy <- full_pred_data |>
  mutate(
    age = dag,
    cit = if_else(dcz == 1, "UK", "Other"),  # leave out as odd in UKMOD?
    disab = factor(
      ddi,
      levels = c("0", "1"),
      labels = c("Not disabled", "Disabled")
    ),
    employment = case_when(
      les %in% 1:3 ~ "Employed",
      les == 5 ~ "Unemployed",
      les %in% 6:7 ~ "Inactive",
      les == 4 ~ "Retired",
      les == 8 ~ "Sick or disabled",
      TRUE ~ "Other"
    ),
    student = if_else(les == 6, 1L, 0L),
    educ = case_when(
      dec == 4 ~ "Degree or College",
      dec == 3 ~ "Secondary",
      dec == 2 ~ "Secondary",
      dec == 5 ~ "Tertiary",
      TRUE ~ "None"
    ),
    gender = factor(
      dgn,
      levels = c("0", "1"),
      labels = c("Female", "Male")
    ),
    marsta = factor(
      if_else(dms == 0, 1L, dms),
      levels = 1:5,
      labels = c("Single", "Married", "Separated", "Divorced", "Widowed")
    ),
    region = if_else(drgn1 < 3, LETTERS[drgn1 + 2], LETTERS[drgn1 + 1]),
    emp_len = case_when(
      les %in% c(4:8) ~ "Not in employment",
      liwwh < 12 ~ "Less than 12 months",
      liwwh < 24 ~ "Between 1 and 2 years",
      liwwh < 60 ~ "Between 2 and 5 years",
      liwwh < 120 ~ "Between 5 and 10 years",
      liwwh < 240 ~ "Between 10 and 20 years",
      liwwh >= 240 ~ "20 years or more",
    ),
    seeking = factor(
      lowas,
      levels = c("0", "1"),
      labels = c("No", "Yes")
    ),
    children = fct_other(factor(children), c("0", "1"), other_level = "2+"),
    income = if_else(yem > 3415, 3415, yem),
    i_0 = as.numeric(income == 0),
    i_m = as.numeric(income == 3415),
    i_l = income * (1 - i_m),
    # i.e. if income is max then turn off the continuous
    i_c = cut(
      income,
      c(0, 1, 500, 1000, 2000, 3000, 3500),
      right = FALSE,
      include.lowest = TRUE,
      labels = c("0",
                 "1-499",
                 "500-999",
                 "1000-1999",
                 "2000-2999",
                 "3000+")
    ),
    house_ten = fct_collapse(factor(amrtn), Mortgaged = "1", Outright = "2", Rented = c("3", "4", "5"), Free = "6", Other = "7"),
    house_resp = factor(dhr, labels = c("No", "Yes")),
    caring = factor(full_pred_data$lcr01 == 0, levels = c(TRUE, FALSE), labels = c("No", "Yes"))
  ) |> 
  select(
    year, idhh, uc_income, lba_income, uc_receipt,
    age, cit, disab, employment, educ, gender, marsta, region, emp_len, seeking, 
    student,
    children, income, i_0, i_m, i_l, i_c, house_ten, house_resp, caring
  )



# predict data from UKMOD -------------------------------------------------

model_data <- ukmod_tidy |> 
  group_by(year, idhh) |> 
  mutate(lba_income = sum(lba_income),
         uc_income = max(uc_income),
         uc_receipt = factor(max(uc_receipt)),
         n_hh_emp = sum(employment == "Employed"),
         n_hh_unemp = sum(employment == "Unemployed"),
         n_hh_inact = sum(employment == "Inactive")) |> 
  ungroup() |> 
  filter(age > 17 & age < 66) |> 
  mutate(
    p_hh_emp = if_else(employment == "Employed" & n_hh_emp > 0, 1L, 0L),
    n_hh_emp = fct_other(factor(n_hh_emp), c("0", "1"), other_level = "2+"),
    n_hh_unemp = fct_other(factor(n_hh_unemp), c("0", "1"), other_level = "2+"),
    n_hh_inact = fct_other(factor(n_hh_inact), c("0", "1"), other_level = "2+"))

data_split <- initial_split(model_data, prop = 0.8, strata = year)

train_data <- training(data_split)
test_data <- testing(data_split)

mc_train_set <- mc_cv(train_data)
cv_train_set <- vfold_cv(train_data, v = 5)


# tuning grid -------------------------------------------------------------

library(doParallel)

cores <- parallel::detectCores()
cl <- parallel::makePSOCKcluster(floor(0.98*cores))

registerDoParallel(cl)

tune_class_xg <- boost_tree(trees = 1000, tree_depth = tune(), min_n = tune(), learn_rate = tune(), loss_reduction = tune()) |>
  set_engine("xgboost") |>
  set_mode("classification")

recipie_tune_class_xg <- workflow() |>
  add_model(tune_class_xg) |>
  add_formula(uc_receipt ~ age +
                i_c +
                region + disab + educ + gender + emp_len + seeking + student +
                house_ten + house_resp + caring + n_hh_emp + n_hh_unemp + n_hh_inact +
                children + employment + marsta)

xg_tune_grid <- tune_class_xg |>
  extract_parameter_set_dials() |>
  grid_regular(levels = 3)

xg_tune_grid$min_n <- rep(c(40, 50, 60), 27)
xg_tune_grid$tree_depth <- rep(rep(c(5, 10, 15), each = 3), 9)


start <- Sys.time()
tune_out_class_xg <-
  tune_grid(
    recipie_tune_class_xg,
    grid = xg_tune_grid,
    resamples = mc_train_set,
    metrics = metric_set(roc_auc),
    control = control_grid(parallel_over = "everything",
                           verbose = TRUE)
  )
Sys.time() - start


saveRDS(tune_out_class_xg, "output/tune_out_class_xg_up.rds")

stopCluster(cl)
